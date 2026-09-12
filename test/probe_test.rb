# frozen_string_literal: true
require "test_helper"
require "socket"

# PLAN 1.2 — probes for :command. A probed child is :starting until its port /
# endpoint answers; a child that never answers within start_timeout is drained
# and counted as a crash.
class ProbeTest < Minitest::Test
  include TelemetryCapture

  FIXTURES = File.expand_path("fixtures", __dir__)

  # Fixtures sleep 0.6s before opening their port, so any :healthy signal in
  # the first 0.2s would be a probe that isn't actually probing.
  BOOT_DELAY = 0.6

  def test_tcp_probe_reports_starting_until_port_answers
    port = free_port
    sup = build_sup(cmd: "ruby #{FIXTURES}/tcp_server.rb #{port} #{BOOT_DELAY}", probe: { tcp: port })
    assert_starting_then_healthy(sup)
  end

  def test_http_probe_reports_starting_until_2xx
    port = free_port
    sup = build_sup(cmd: "ruby #{FIXTURES}/http_server.rb #{port} #{BOOT_DELAY}",
                    probe: { http: "http://127.0.0.1:#{port}/up" })
    assert_starting_then_healthy(sup)
  end

  def test_start_timeout_drains_and_applies_strategy
    port = free_port # nothing ever listens on it
    sup = OtpRails::Supervisor.new(strategy: :one_for_one,
                                   intensity: OtpRails::RestartIntensity.new(max_restarts: 1, within: 60),
                                   backoff: OtpRails::Backoff.new(kind: :none))
    sup.add_child(OtpRails::ChildSpec.new(id: :mute, adapter: :command, shutdown: 2, start_timeout: 1,
                                          opts: { cmd: "sleep 30", probe: { tcp: port } }))
    capture_events do |events|
      assert_raises(OtpRails::Escalation) { sup.run }
      drains = events.count { |e| e[:event].last == :drain && e[:metadata][:id] == :mute }
      assert_operator drains, :>=, 1, "start_timeout must drain the child"
      assert events.any? { |e| e[:event].last == :restart && e[:metadata][:id] == :mute },
             "the drained start must count as a crash and apply the strategy"
      refute events.any? { |e| e[:event].last == :healthy && e[:metadata][:id] == :mute },
             "a child that never answers its probe must never be :healthy"
    end
  end

  private

  def build_sup(cmd:, probe:)
    sup = OtpRails::Supervisor.new
    sup.add_child(OtpRails::ChildSpec.new(id: :probed, adapter: :command, shutdown: 2, start_timeout: 10,
                                          opts: { cmd: cmd, probe: probe }))
    sup
  end

  def assert_starting_then_healthy(sup)
    capture_events do |events|
      t = Thread.new { sup.run }
      sleep 0.2
      assert healthy_events(events).empty?,
             "child must be :starting while its port is closed (fixture opens it after #{BOOT_DELAY}s)"
      assert wait_until(10) { healthy_events(events).any? }, "child should become :healthy once the probe answers"
      sup.stop
      assert t.join(10), "supervisor should stop cleanly"
    end
  end

  def healthy_events(events)
    events.select { |e| e[:event].last == :healthy && e[:metadata][:id] == :probed }
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
