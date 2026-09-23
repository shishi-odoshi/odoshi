# frozen_string_literal: true
require "test_helper"

# Issue #60 — every tree mutation runs on the control loop, so @live,
# @heartbeats and @hb_floor have exactly one writer and Process.fork only
# ever happens on one thread (the fork-safety rule). restart! is therefore
# fire-and-forget: callers observe the effect, not a return value.
class SingleWriterTest < Minitest::Test
  include TelemetryCapture

  def test_restart_is_queued_not_executed_on_the_caller_thread
    sup = build
    capture_events do |events|
      t = Thread.new { sup.run }
      assert wait_until(10) { sup.live_pid(:a) }, "child should start"
      before = sup.live_pid(:a)

      # The call itself must not drain or spawn anything — it only enqueues.
      # Checked immediately: a synchronous implementation would already have
      # replaced the child by the time restart! returned.
      assert_equal true, sup.restart!(:a)
      assert_equal before, sup.live_pid(:a),
                   "restart! must not mutate the tree on the caller's thread"

      assert wait_until(10) { spawns(events, :a) >= 2 }, "the loop should apply the restart"
      refute_equal before, sup.live_pid(:a), "child should have been replaced"
      sup.stop
      assert t.join(10)
    end
  end

  def test_concurrent_restarts_from_many_threads_leave_one_live_child
    sup = build
    capture_events do |events|
      t = Thread.new { sup.run }
      assert wait_until(10) { sup.live_pid(:a) }, "child should start"

      # 20 threads hammering restart! — with mutation on the caller thread
      # this raced @live and could fork from 20 threads at once.
      20.times.map { Thread.new { sup.restart!(:a) } }.each(&:join)
      assert wait_until(15) { spawns(events, :a) >= 2 }, "restarts should be applied"

      # Shutdown must preempt the queued remainder rather than waiting for
      # all 20 to drain and respawn (#28's rule applied to queued restarts).
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sup.stop
      assert t.join(15), "supervisor should stop cleanly after a restart storm"
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10,
                      "stop must preempt queued restarts, not queue behind them"
      # No duplicate live child and no orphan left by a racing fork: every
      # spawn is accounted for by a drain.
      assert_equal spawns(events, :a), events.count { |e| e[:event].last == :drain && e[:metadata][:id] == :a },
                   "every spawned child should have been drained exactly once"
    end
  end

  def test_restart_of_an_unknown_id_is_ignored_rather_than_crashing_the_loop
    sup = build
    capture_events do |events|
      t = Thread.new { sup.run }
      assert wait_until(10) { sup.live_pid(:a) }
      sup.restart!(:nonexistent) # would raise ArgumentError inside the loop pre-fix
      sleep 0.3
      assert t.alive?, "an unknown id must not take down the control loop"
      sup.restart!(:a)
      assert wait_until(10) { spawns(events, :a) >= 2 }, "the tree must still be operational"
      sup.stop
      assert t.join(10)
    end
  end

  private

  def build
    sup = Odoshi::Supervisor.new(strategy: :one_for_one,
                                 intensity: Odoshi::RestartIntensity.new(max_restarts: 50, within: 60),
                                 backoff: Odoshi::Backoff.new(kind: :none))
    sup.add_child(Odoshi::ChildSpec.new(id: :a, adapter: :command, shutdown: 2,
                                        opts: { cmd: "sleep 30" }))
    sup
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
