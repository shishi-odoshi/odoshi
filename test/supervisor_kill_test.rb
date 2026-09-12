# frozen_string_literal: true
require "test_helper"

# The chaos test that gates Phase 1: kill a child, assert it comes back; exceed intensity, assert escalation.
class SupervisorKillTest < Minitest::Test
  include TelemetryCapture

  def build(strategy: :one_for_one, max_restarts: 5)
    sup = OtpRails::Supervisor.new(strategy: strategy,
                                   intensity: OtpRails::RestartIntensity.new(max_restarts: max_restarts, within: 60),
                                   backoff: OtpRails::Backoff.new(kind: :none))
    sup.add_child(OtpRails::ChildSpec.new(id: :a, adapter: :command, shutdown: 2, opts: { cmd: "sleep 30" }))
    sup.add_child(OtpRails::ChildSpec.new(id: :b, adapter: :command, shutdown: 2, opts: { cmd: "sleep 30" }))
    sup
  end

  def run_and_kill(sup, victim)
    capture_events do |events|
      t = Thread.new { sup.run }
      sleep 0.3
      Process.kill("KILL", sup.live_pid(victim))
      sleep 0.5
      sup.stop
      t.join(5)
      yield events
    end
  end

  def test_killed_child_is_restarted
    run_and_kill(build, :a) do |events|
      assert_equal 2, spawns(events, :a), "child :a should have been spawned twice"
      assert_equal 1, spawns(events, :b), "one_for_one must not touch :b"
      assert events.any? { |e| e[:event].last == :restart && e[:metadata][:id] == :a }
    end
  end

  def test_rest_for_one_restarts_siblings_after_failed_child
    run_and_kill(build(strategy: :rest_for_one), :a) do |events|
      assert_equal 2, spawns(events, :a)
      assert_equal 2, spawns(events, :b), "rest_for_one must restart :b after :a"
    end
  end

  def test_escalates_when_intensity_exceeded
    sup = OtpRails::Supervisor.new(strategy: :one_for_one,
                                   intensity: OtpRails::RestartIntensity.new(max_restarts: 1, within: 60),
                                   backoff: OtpRails::Backoff.new(kind: :none))
    sup.add_child(OtpRails::ChildSpec.new(id: :crashy, adapter: :command, shutdown: 1, opts: { cmd: "exit 1" }))
    assert_raises(OtpRails::Escalation) { sup.run }
  end
end
