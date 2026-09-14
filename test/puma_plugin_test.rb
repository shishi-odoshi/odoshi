# frozen_string_literal: true
require "test_helper"
require "net/http"
require "socket"
require "tmpdir"

# PLAN 2.5 — puma plugin: the master heartbeats worker-level state over the
# §5 socket. A missing worker ⇒ reported "degraded" ⇒ [:odoshi, :child,
# :degraded] telemetry — while puma replaces its own worker and the
# supervisor changes NO lifecycle (the child is never respawned).
class PumaPluginTest < Minitest::Test
  include TelemetryCapture

  RACK_APP = File.expand_path("fixtures/rack_app", __dir__)
  WAIT = 30 # cluster boot forks two workers; generous, not load-bearing

  def test_missing_worker_reports_degraded_then_recovers_without_child_restart
    with_plugin_sup("puma_cluster.rb") do |sup, events|
      assert wait_until(WAIT) { heartbeat_state(sup) == "healthy" },
             "cluster should heartbeat healthy once both workers boot"

      workers = worker_pids(sup.live_pid(:web))
      assert_equal 2, workers.size, "fixture runs two workers"
      Process.kill("KILL", workers.first)

      assert wait_until(WAIT) { degraded_count(events) >= 1 },
             "a missing worker must surface as child.degraded telemetry"
      assert wait_until(WAIT) { heartbeat_state(sup) == "healthy" },
             "puma should replace its own worker and report healthy again"
      assert_equal 1, spawns(events, :web),
             "worker loss is visibility only — the supervisor must not respawn the child"
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
                                     "BOOT_DELAY" => "3.0" } }
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
