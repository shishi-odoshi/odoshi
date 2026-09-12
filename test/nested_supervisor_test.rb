# frozen_string_literal: true
require "test_helper"
require "tmpdir"

# PLAN 1.7 — nested supervisors (DESIGN §3.1). A subtree is a :supervisor
# child of the parent: it runs its own strategy/intensity/backoff, and
# exceeding the SUBTREE's intensity surfaces to the PARENT as a crashed child,
# to which the parent applies ITS strategy/intensity.
class NestedSupervisorTest < Minitest::Test
  include TelemetryCapture

  FIXTURES = File.expand_path("fixtures", __dir__)

  def test_subtree_children_start_and_appear_in_telemetry
    sup = OtpRails.supervise do
      socket nil
      child :top, adapter: :command, cmd: "sleep 30", shutdown: 2
      supervisor :background, shutdown: 10 do
        strategy :one_for_one
        child :bg1, adapter: :command, cmd: "sleep 30", shutdown: 2
        child :bg2, adapter: :command, cmd: "sleep 30", shutdown: 2
      end
    end
    capture_events do |events|
      t = Thread.new { sup.run }
      assert wait_until(15) { %i[top background bg1 bg2].all? { |id| spawns(events, id) == 1 } },
             "parent children and subtree children should all spawn (got: #{events.select { |e| e[:event].last == :spawn }.map { |e| e[:metadata][:id] }})"
      bg_pids = %i[bg1 bg2].map { |id| events.find { |e| e[:event].last == :spawn && e[:metadata][:id] == id }[:metadata][:pid] }
      bg_pids.each { |pid| assert Process.kill(0, pid), "subtree child pid #{pid} should be a real live process" }
      sup.stop
      assert t.join(20), "supervisor should shut down"
    end
  end

  # THE acceptance test: a crashy child inside the subtree exceeds the
  # SUBTREE's intensity (1 restart / 60s). The subtree escalates, which the
  # parent sees as a crashed :background child; the parent restarts the WHOLE
  # subtree. The fresh subtree gets a fresh intensity window, so the fixture's
  # third crash does NOT re-escalate — it restarts in-subtree and settles.
  def test_parent_restarts_whole_subtree_when_it_exceeds_its_intensity
    Dir.mktmpdir do |dir|
      counter = File.join(dir, "crashes")
      log = File.join(dir, "worker.log")
      sup = OtpRails.supervise do
        socket nil
        backoff :none
        max_restarts 5, within: 60
        supervisor :background, shutdown: 10 do
          strategy :one_for_one
          max_restarts 1, within: 60
          backoff :none
          child :bg_worker, adapter: :command, shutdown: 5,
                cmd: "ruby #{FIXTURES}/term_logger.rb bg_worker #{log} 0.1"
          child :crashy, adapter: :command, shutdown: 2,
                cmd: "ruby #{FIXTURES}/crash_n_times.rb #{counter} 3"
        end
      end
      capture_events do |events|
        t = Thread.new { sup.run }
        # Settled state: crashy's 4th run (2 crashes -> subtree escalates ->
        # parent restarts subtree -> 1 more crash -> in-subtree restart) stays up.
        assert wait_until(30) { File.exist?(counter) && File.read(counter).to_i >= 4 && spawns(events, :bg_worker) >= 2 },
               "subtree should crash-cycle, escalate, be restarted by the parent, then settle"
        sleep 0.5 # let the final spawns/telemetry land

        assert_equal 2, spawns(events, :background), "parent must restart the whole subtree exactly once"
        assert_equal 2, spawns(events, :bg_worker), "healthy sibling must respawn with the fresh subtree"
        assert_equal 4, spawns(events, :crashy), "crashy: 2 runs per subtree generation"
        assert events.any? { |e| e[:event].last == :restart && e[:metadata][:id] == :background },
               "parent must emit child.restart for the subtree"
        assert events.any? { |e| e[:event] == %i[otp_rails supervisor escalate] },
               "the subtree must emit supervisor.escalate when its intensity is exceeded"

        # The escalated subtree must have drained its own children before the
        # parent replaced it: gen-1 worker pid gone, gen-2 worker pid alive.
        worker_pids = events.select { |e| e[:event].last == :spawn && e[:metadata][:id] == :bg_worker }
                            .map { |e| e[:metadata][:pid] }
        assert wait_until(10) { !alive?(worker_pids.first) }, "gen-1 subtree worker must not be orphaned"
        assert alive?(worker_pids.last), "gen-2 subtree worker should be running"

        sup.stop
        assert t.join(20), "supervisor should shut down"
        ups = File.readlines(log).count { |l| l.start_with?("UP") }
        exits = File.readlines(log).count { |l| l.start_with?("EXIT") }
        assert_equal 2, ups, "worker should have run in both subtree generations"
        assert_equal ups, exits, "every subtree worker must have been drained (no orphans)"
      end
    end
  end

  def test_parent_stop_drains_subtree_children_too
    Dir.mktmpdir do |dir|
      log = File.join(dir, "events.log")
      sup = OtpRails.supervise do
        socket nil
        child :top, adapter: :command, shutdown: 5,
              cmd: "ruby #{FIXTURES}/term_logger.rb top #{log} 0.1"
        supervisor :background, shutdown: 15 do
          child :bg1, adapter: :command, shutdown: 5,
                cmd: "ruby #{FIXTURES}/term_logger.rb bg1 #{log} 0.1"
          child :bg2, adapter: :command, shutdown: 5,
                cmd: "ruby #{FIXTURES}/term_logger.rb bg2 #{log} 0.1"
        end
      end
      t = Thread.new { sup.run }
      assert wait_until(15) { File.exist?(log) && File.readlines(log).count { |l| l.start_with?("UP") } == 3 },
             "all three children (parent + subtree) should report UP"
      sup.stop
      assert t.join(25), "supervisor should shut down"

      lines = File.readlines(log).map(&:split)
      %w[top bg1 bg2].each do |id|
        assert lines.include?(["EXIT", id]), "#{id} must have been drained to a clean exit (no orphans)"
      end
      # Reverse start order: the subtree (declared last) is drained fully
      # before :top; within the subtree, bg2 before bg1.
      tagged = lines.reject { |tag,| tag == "UP" }.map { |tag, id| "#{tag}:#{id}" }
      assert_operator tagged.index("EXIT:bg1"), :<, tagged.index("TERM:top"),
                      "the subtree must be fully drained before earlier-declared parent children"
      assert_operator tagged.index("TERM:bg2"), :<, tagged.index("TERM:bg1"),
                      "subtree children drain in reverse start order"
    end
  end

  def test_escalation_beyond_parent_intensity_raises_out_of_the_root
    sup = OtpRails.supervise do
      socket nil
      backoff :none
      max_restarts 1, within: 60
      supervisor :background, shutdown: 5 do
        max_restarts 0, within: 60
        backoff :none
        child :crashy, adapter: :command, cmd: "exit 1", shutdown: 1
      end
    end
    capture_events do |events|
      assert_raises(OtpRails::Escalation) { sup.run }
      assert_equal 2, spawns(events, :background),
                   "parent should have restarted the subtree once before giving up"
    end
  end

  private

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
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
