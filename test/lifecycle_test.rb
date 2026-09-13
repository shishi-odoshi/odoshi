# frozen_string_literal: true
require "test_helper"
require "socket"

# QA #28/#19/#20 — shutdown promptness and restart-lifecycle hygiene.
class LifecycleTest < Minitest::Test
  include TelemetryCapture

  # Issue #28: stop() while a child is stuck in wait_healthy must not wait
  # out start_timeout (platforms SIGKILL after their grace period).
  def test_stop_is_prompt_while_a_child_is_stuck_starting
    port = free_port # nothing ever listens
    sup = OtpRails::Supervisor.new
    sup.add_child(OtpRails::ChildSpec.new(id: :stuck, adapter: :command, shutdown: 2, start_timeout: 30,
                                          opts: { cmd: "sleep 30", probe: { tcp: port } }))
    capture_events do |events|
      t = Thread.new { sup.run }
      assert wait_until(10) { spawns(events, :stuck) >= 1 }, "child should spawn"
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sup.stop
      assert t.join(5), "stop during wait_healthy must complete promptly (was: blocked ~start_timeout)"
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    end
  end

  # Issue #19: one healthy health_interval resets the backoff ladder — a
  # rarely-crashing child must not converge to permanent max backoff.
  def test_backoff_attempts_reset_after_a_healthy_interval
    sup = OtpRails::Supervisor.new(strategy: :one_for_one,
                                   intensity: OtpRails::RestartIntensity.new(max_restarts: 10, within: 60),
                                   backoff: OtpRails::Backoff.new(kind: :exponential, base: 0.05, cap: 1))
    sup.add_child(OtpRails::ChildSpec.new(id: :a, adapter: :command, shutdown: 2, health_interval: 0.2,
                                          opts: { cmd: "sleep 30" }))
    capture_events do |events|
      t = Thread.new { sup.run }
      2.times do |round|
        assert wait_until(10) { spawns(events, :a) >= round + 1 }, "child should be up (round #{round + 1})"
        sleep 0.7 # > 2 health intervals: monitor observes :healthy and resets attempts
        Process.kill("KILL", sup.live_pid(:a))
        assert wait_until(10) { restart_attempts(events, :a).size >= round + 1 }, "child should restart"
      end
      assert_equal [1, 1], restart_attempts(events, :a).first(2),
                   "a healthy interval must reset attempts (was: [1, 2] — monotonic forever)"
      sup.stop
      assert t.join(10)
    end
  end

  # Issue #20: a child that exits and is not restarted must leave no stale
  # @live entry — no corpse drains at shutdown, no ghost live_pid.
  def test_non_restarted_children_leave_no_stale_entry
    sup = OtpRails::Supervisor.new
    sup.add_child(OtpRails::ChildSpec.new(id: :tmp, adapter: :command, restart: :temporary,
                                          shutdown: 2, opts: { cmd: "exit 0" }))
    sup.add_child(OtpRails::ChildSpec.new(id: :keeper, adapter: :command, shutdown: 2,
                                          opts: { cmd: "sleep 30" }))
    capture_events do |events|
      t = Thread.new { sup.run }
      assert wait_until(10) { events.any? { |e| e[:event].last == :exit && e[:metadata][:id] == :tmp } },
             "temporary child should exit"
      assert wait_until(5) { sup.live_pid(:tmp).nil? }, "stale @live entry must be pruned"
      sup.stop
      assert t.join(10)
      drains = events.count { |e| e[:event].last == :drain && e[:metadata][:id] == :tmp }
      assert_equal 0, drains, "shutdown must not emit drain telemetry for a long-dead child"
    end
  end

  # Issue #15: a cmd that cannot be spawned is a child crash like any other —
  # restart, backoff, escalate, exit 70. It previously crashed the whole
  # supervisor with a raw Errno::ENOENT on macOS (exit 1) while Linux
  # restart-looped to escalation: same misconfig, different behavior.
  def test_unspawnable_command_counts_as_a_crash_and_escalates
    sup = OtpRails::Supervisor.new(strategy: :one_for_one,
                                   intensity: OtpRails::RestartIntensity.new(max_restarts: 1, within: 60),
                                   backoff: OtpRails::Backoff.new(kind: :none))
    sup.add_child(OtpRails::ChildSpec.new(id: :bad, adapter: :command, shutdown: 1,
                                          opts: { cmd: "definitely-not-a-real-binary-xyz" }))
    capture_events do |events|
      assert_raises(OtpRails::Escalation) { sup.run }
      exit_codes = events.select { |e| e[:event].last == :exit && e[:metadata][:id] == :bad }
                         .map { |e| e[:measurements][:exit_code] }.uniq
      assert_equal [127], exit_codes, "an unspawnable cmd must surface as exit 127, not a raised exception"
    end
  end

  private

  def restart_attempts(events, id)
    events.select { |e| e[:event].last == :restart && e[:metadata][:id] == id }
          .map { |e| e[:metadata][:attempt] }
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
