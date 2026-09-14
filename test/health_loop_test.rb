# frozen_string_literal: true
require "test_helper"
require "socket"
require "tmpdir"
require "fileutils"

# PLAN 1.3 — periodic health loop: a per-child monitor thread polls health at
# health_interval. :degraded emits telemetry only, unless
# degraded_restart_after consecutive reports accumulate — then the child is
# drained and the strategy applies. Fixture flips 200 → 503 on a flag file.
class HealthLoopTest < Minitest::Test
  include TelemetryCapture

  FIXTURES = File.expand_path("fixtures", __dir__)

  def test_degraded_emits_telemetry_only
    with_flaky_child(degraded_restart_after: nil) do |sup, events, flag|
      FileUtils.touch(flag)
      assert wait_until(10) { degraded_count(events) >= 2 }, "degraded reports should keep arriving"
      assert_equal 1, spawns(events, :flaky), ":degraded alone must never restart the child"
    end
  end

  def test_consecutive_degraded_reports_trigger_restart
    with_flaky_child(degraded_restart_after: 2) do |sup, events, flag|
      FileUtils.touch(flag)
      assert wait_until(10) { degraded_count(events) >= 2 }, "should reach the degraded threshold"
      File.delete(flag) # recover the backend so the replacement child comes up healthy
      assert wait_until(10) { spawns(events, :flaky) >= 2 },
             "#{degraded_count(events)} consecutive :degraded must drain and restart the child"
      assert wait_until(10) { healthy_count(events) >= 2 }, "the replacement child should become healthy"
      assert events.any? { |e| e[:event].last == :restart && e[:metadata][:id] == :flaky },
             "the degraded drain must count as a crash and apply the strategy"
    end
  end

  private

  # One :command child running the flaky HTTP fixture, probed on /up, with a
  # fast health_interval so tests stay quick but not tight enough to flake.
  def with_flaky_child(degraded_restart_after:)
    Dir.mktmpdir do |dir|
      flag = File.join(dir, "sick.flag")
      port = free_port
      sup = Odoshi::Supervisor.new(strategy: :one_for_one,
                                     intensity: Odoshi::RestartIntensity.new(max_restarts: 10, within: 60),
                                     backoff: Odoshi::Backoff.new(kind: :none))
      sup.add_child(Odoshi::ChildSpec.new(
                      id: :flaky, adapter: :command, shutdown: 2, start_timeout: 10,
                      health_interval: 0.2, degraded_restart_after: degraded_restart_after,
                      opts: { cmd: "ruby #{FIXTURES}/flaky_http_server.rb #{port} #{flag}",
                              probe: { http: "http://127.0.0.1:#{port}/up" } }
                    ))
      capture_events do |events|
        t = Thread.new { sup.run }
        assert wait_until(10) { healthy_count(events) >= 1 }, "child should come up healthy"
        yield sup, events, flag
        sup.stop
        assert t.join(10), "supervisor should stop cleanly"
      end
    end
  end

  def degraded_count(events)
    events.count { |e| e[:event].last == :degraded && e[:metadata][:id] == :flaky }
  end

  def healthy_count(events)
    events.count { |e| e[:event].last == :healthy && e[:metadata][:id] == :flaky }
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
