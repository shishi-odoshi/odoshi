# frozen_string_literal: true
require "test_helper"
require "tmpdir"

# PLAN 1.6 — :solid_queue adapter: wraps bin/jobs, judged by the ACTIVE
# heartbeat (sent via the Rails-free OtpRails::Heartbeat helper), not the DB.
# Acceptance: a fixture child using Heartbeat; kill it; assert restart.
class SolidQueueTest < Minitest::Test
  include TelemetryCapture

  FIXTURES = File.expand_path("fixtures", __dir__)

  def test_heartbeating_jobs_child_is_active_and_restarts_when_killed
    Dir.mktmpdir do |dir|
      sup = OtpRails::Supervisor.new(strategy: :one_for_one,
                                     intensity: OtpRails::RestartIntensity.new(max_restarts: 5, within: 60),
                                     backoff: OtpRails::Backoff.new(kind: :none),
                                     socket_path: File.join(dir, "s.sock"))
      sup.add_child(OtpRails::ChildSpec.new(id: :jobs, adapter: :solid_queue, shutdown: 2,
                                            health_interval: 0.2,
                                            opts: { cmd: "ruby #{FIXTURES}/heartbeat_child.rb jobs 0.1" }))
      capture_events do |events|
        t = Thread.new { sup.run }
        assert wait_until(10) { sup.instance_variable_get(:@heartbeats).key?(:jobs) },
               "the Heartbeat helper should register the child as active"
        Process.kill("KILL", sup.live_pid(:jobs))
        assert wait_until(10) { spawns(events, :jobs) >= 2 }, "killed jobs child should be restarted"
        assert wait_until(10) { sup.instance_variable_get(:@heartbeats).key?(:jobs) },
               "the replacement child should heartbeat too"
        sup.stop
        assert t.join(10), "supervisor should stop cleanly"
      end
    end
  end

  def test_default_command_is_bin_jobs
    spec = OtpRails::ChildSpec.new(id: :jobs, adapter: :solid_queue, opts: {})
    derived = OtpRails::Adapters::SolidQueue.new.send(:command_spec, spec)
    assert_equal "bin/jobs", derived.opts[:cmd]
    spec = OtpRails::ChildSpec.new(id: :jobs, adapter: :solid_queue, opts: { cmd: "bin/other" })
    derived = OtpRails::Adapters::SolidQueue.new.send(:command_spec, spec)
    assert_equal "bin/other", derived.opts[:cmd]
  end

  def test_heartbeat_helper_is_a_noop_when_unsupervised
    old_sock, old_token = ENV.delete("OTP_RAILS_SOCK"), ENV.delete("OTP_RAILS_TOKEN")
    assert_nil OtpRails::Heartbeat.start(id: "jobs"), "must not beat without a supervising socket"
  ensure
    ENV["OTP_RAILS_SOCK"] = old_sock if old_sock
    ENV["OTP_RAILS_TOKEN"] = old_token if old_token
  end

  private

  def wait_until(timeout)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
    true
  end
end
