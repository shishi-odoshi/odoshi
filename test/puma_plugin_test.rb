# frozen_string_literal: true
require "test_helper"
require "net/http"
require "socket"
require "tmpdir"
require "fileutils"

# PLAN 2.5 — puma plugin: the master heartbeats worker-level state over the
# §5 socket. A missing worker ⇒ reported "degraded" ⇒ [:odoshi, :child,
# :degraded] telemetry — while puma replaces its own worker and the
# supervisor changes NO lifecycle (the child is never respawned).
class PumaPluginTest < Minitest::Test
  include TelemetryCapture

  RACK_APP = File.expand_path("fixtures/rack_app", __dir__)
  WAIT = 30 # cluster boot forks two workers; generous, not load-bearing
  REAP_WAIT = 90 # puma-master reap latency reached ~28s on starved macOS CI

  def test_missing_worker_reports_degraded_then_recovers_without_child_restart
    with_plugin_sup("puma_cluster.rb") do |sup, events|
      assert wait_until(WAIT) { heartbeat_state(sup) == "healthy" },
             "cluster should heartbeat healthy once both workers boot"

      workers = worker_pids(sup.live_pid(:web))
      assert_equal 2, workers.size, "fixture runs two workers"
      Process.kill("KILL", workers.first)

      # One kill, then a LONG observation deadline: stats can't show a
      # missing worker until puma's master reaps the corpse, and a starved
      # macOS CI runner was observed taking ~28s to reap (locally it's
      # instant). Once reaped, the 5s replacement boot gives the degraded
      # window; the chain itself needs no luck — just patience. On failure,
      # dump the chain state: which link is dead — plugin beats (states
      # never leave healthy) or the supervisor monitor (degraded states
      # recorded but no telemetry)?
      states = []
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + REAP_WAIT
      while degraded_count(events) < 1 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        states << sup.instance_variable_get(:@heartbeats).dig(:web, :state)
        sleep 0.5
      end
      monitor = sup.instance_variable_get(:@live).dig(:web, :monitor)
      assert_operator degraded_count(events), :>=, 1,
                      "a missing worker must surface as child.degraded telemetry — " \
                      "states_seen=#{states.uniq.inspect} monitor_alive=#{monitor&.alive?.inspect} " \
                      "hb=#{sup.instance_variable_get(:@heartbeats)[:web].inspect} " \
                      "events=#{events.map { |e| e[:event].last }.tally.inspect}"
      assert wait_until(WAIT) { heartbeat_state(sup) == "healthy" },
             "puma should replace its own worker and report healthy again"
      assert_equal 1, spawns(events, :web),
             "worker loss is visibility only — the supervisor must not respawn the child"
    end
  end

  # Issue #49: the plugin's heartbeat must never vouch for an app whose /up
  # is failing — under §5 active-first health, a "healthy" heartbeat would
  # out-vote the probe and silently disable wedge detection. The plugin now
  # reports the WORSE of worker topology and /up, so the wedge surfaces as
  # degraded heartbeats and degraded_restart_after replaces the child.
  def test_wedged_app_is_not_masked_by_the_plugin_heartbeat
    Dir.mktmpdir do |dir|
      flag = File.join(dir, "wedge.flag")
      port = free_port
      sup = Odoshi::Supervisor.new(strategy: :one_for_one,
                                   intensity: Odoshi::RestartIntensity.new(max_restarts: 10, within: 60),
                                   backoff: Odoshi::Backoff.new(kind: :none),
                                   socket_path: File.join(dir, "s.sock"))
      sup.add_child(Odoshi::ChildSpec.new(
                      id: :web, adapter: :puma, shutdown: 5, start_timeout: WAIT,
                      health_interval: 0.2, degraded_restart_after: 3,
                      opts: { config: "#{RACK_APP}/puma_flaky_plugin.rb", port: port,
                              env: { "PUMA_TEST_PORT" => port.to_s, "ODOSHI_HEARTBEAT_INTERVAL" => "0.1",
                                     "WEDGE_FLAG" => flag } }
                    ))
      capture_events do |events|
        t = Thread.new { sup.run }
        assert wait_until(WAIT) { heartbeat_state(sup) == "healthy" }, "app should come up healthy"
        FileUtils.touch(flag) # wedge: alive, heartbeating, /up now 503
        # Hold the wedge until the degraded_restart_after threshold (3) is
        # crossed — the third observation is what enqueues the replacement.
        assert wait_until(WAIT) { degraded_count(events) >= 3 },
               "the wedge must surface through the heartbeat, not be masked by it"
        File.delete(flag) # let the replacement boot healthy
        assert wait_until(WAIT) { spawns(events, :web) >= 2 },
               "degraded_restart_after must replace the wedged child"
        assert wait_until(WAIT) { heartbeat_state(sup) == "healthy" }, "replacement should recover"
        sup.stop
        assert t.join(WAIT), "supervisor should stop cleanly"
      end
    end
  end

  def test_single_mode_plugin_heartbeats_healthy
    with_plugin_sup("puma_single_plugin.rb") do |sup, _events|
      assert wait_until(WAIT) { heartbeat_state(sup) == "healthy" },
             "single-mode plugin should heartbeat healthy (no workers to count)"
    end
  end

  private

  # A :puma child with the plugin fixture, fast heartbeats, and the socket on.
  # No ODOSHI_CHILD_ID is passed: the adapter must inject it (the plugin
  # heartbeating as :web proves that end-to-end).
  def with_plugin_sup(config)
    Dir.mktmpdir do |dir|
      port = free_port
      sup = Odoshi::Supervisor.new(strategy: :one_for_one,
                                     intensity: Odoshi::RestartIntensity.new(max_restarts: 5, within: 60),
                                     backoff: Odoshi::Backoff.new(kind: :none),
                                     socket_path: File.join(dir, "s.sock"))
      sup.add_child(Odoshi::ChildSpec.new(
                      id: :web, adapter: :puma, shutdown: 5, start_timeout: WAIT, health_interval: 0.2,
                      opts: { config: "#{RACK_APP}/#{config}", port: port,
                              env: { "PUMA_TEST_PORT" => port.to_s, "ODOSHI_HEARTBEAT_INTERVAL" => "0.1",
                                     # 3s worker boot ⇒ the missing-worker window is wide
                                     # enough to survive scheduling starvation on loaded
                                     # 2-vCPU CI runners (1s flaked there once).
                                     # 5s replacement-worker boot: 3s flaked on loaded
                                     # macOS CI runners once the 0.4.0 parallel tests
                                     # joined the suite (window race, not a mechanism bug)
                                     "BOOT_DELAY" => "5.0" } }
                    ))
      capture_events do |events|
        t = Thread.new { sup.run }
        assert wait_until(WAIT) { spawns(events, :web) >= 1 }, "puma should spawn"
        yield sup, events
        sup.stop
        assert t.join(WAIT), "supervisor should stop cleanly"
      end
    end
  end

  def heartbeat_state(sup)
    sup.instance_variable_get(:@heartbeats).dig(:web, :state)
  end

  def worker_pids(master_pid)
    `pgrep -P #{master_pid}`.split.map(&:to_i)
  end

  def degraded_count(events)
    events.count { |e| e[:event].last == :degraded && e[:metadata][:id] == :web }
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def wait_until(timeout)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
    true
  end
end
