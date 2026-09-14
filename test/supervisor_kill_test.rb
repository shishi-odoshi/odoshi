# frozen_string_literal: true
require "test_helper"

# The chaos test that gates Phase 1: kill a child, assert it comes back; exceed intensity, assert escalation.
class SupervisorKillTest < Minitest::Test
  include TelemetryCapture

  def build(strategy: :one_for_one, max_restarts: 5)
    sup = Odoshi::Supervisor.new(strategy: strategy,
                                   intensity: Odoshi::RestartIntensity.new(max_restarts: max_restarts, within: 60),
                                   backoff: Odoshi::Backoff.new(kind: :none))
    sup.add_child(Odoshi::ChildSpec.new(id: :a, adapter: :command, shutdown: 2, opts: { cmd: "sleep 30" }))
    sup.add_child(Odoshi::ChildSpec.new(id: :b, adapter: :command, shutdown: 2, opts: { cmd: "sleep 30" }))
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

  # Issue #14: declaration order encodes dependency, so the fan-out must stop
  # ALL affected children in reverse order BEFORE restarting any — never boot
  # a replacement :b while the old :c that depended on dead-:b still runs.
  def test_rest_for_one_stops_all_affected_in_reverse_before_restarting
    require "tmpdir"
    Dir.mktmpdir do |dir|
      log = File.join(dir, "events.log")
      fixtures = File.expand_path("fixtures", __dir__)
      sup = Odoshi::Supervisor.new(strategy: :rest_for_one,
                                     intensity: Odoshi::RestartIntensity.new(max_restarts: 5, within: 60),
                                     backoff: Odoshi::Backoff.new(kind: :none))
      sup.add_child(Odoshi::ChildSpec.new(id: :a, adapter: :command, shutdown: 5, opts: { cmd: "sleep 30" }))
      sup.add_child(Odoshi::ChildSpec.new(id: :b, adapter: :command, shutdown: 5,
                                            opts: { cmd: "ruby #{fixtures}/term_logger.rb b #{log} 0.1" }))
      sup.add_child(Odoshi::ChildSpec.new(id: :c, adapter: :command, shutdown: 5,
                                            opts: { cmd: "ruby #{fixtures}/term_logger.rb c #{log} 0.1" }))
      capture_events do |events|
        t = Thread.new { sup.run }
        wait_for { File.exist?(log) && File.readlines(log).count { |l| l.start_with?("UP") } == 2 }
        Process.kill("KILL", sup.live_pid(:a))
        wait_for { File.readlines(log).count { |l| l.start_with?("UP") } == 4 }
        sup.stop
        t.join(10)
        restart_window = File.readlines(log).map { |l| l.split.first(2).join(":") }[2, 6]
        assert_equal %w[TERM:c EXIT:c TERM:b EXIT:b], restart_window.first(4),
                     "fan-out must stop ALL affected children in reverse order before any restart"
        # UP write order between the two fresh fixtures is a boot race; what
        # matters is that both boot strictly after every drain completed.
        assert_equal %w[UP:b UP:c], restart_window.last(2).sort
        assert_equal 2, spawns(events, :b)
        assert_equal 2, spawns(events, :c)
      end
    end
  end

  def wait_for(timeout = 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timeout" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end

  def test_escalates_when_intensity_exceeded
    sup = Odoshi::Supervisor.new(strategy: :one_for_one,
                                   intensity: Odoshi::RestartIntensity.new(max_restarts: 1, within: 60),
                                   backoff: Odoshi::Backoff.new(kind: :none))
    sup.add_child(Odoshi::ChildSpec.new(id: :crashy, adapter: :command, shutdown: 1, opts: { cmd: "exit 1" }))
    assert_raises(Odoshi::Escalation) { sup.run }
  end
end
