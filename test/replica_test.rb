# frozen_string_literal: true
require "test_helper"
require "socket"
require "json"
require "tmpdir"

# 0.4.0 P1 — replicas: `count: N` expands into N interchangeable peers that
# occupy ONE declaration slot. A replica crash touches nothing else; an
# earlier slot's crash restarts the whole group; the group restarts as a
# unit over the control socket.
class ReplicaTest < Minitest::Test
  include TelemetryCapture

  def test_dsl_expands_count_into_grouped_replicas
    sup = Odoshi.supervise do
      socket nil
      child :web,  adapter: :command, cmd: "sleep 30"
      child :jobs, adapter: :command, cmd: "sleep 30", count: 3
    end
    assert_equal %i[web jobs.1 jobs.2 jobs.3], sup.ids
    groups = sup.children.map(&:group)
    assert_equal [nil, :jobs, :jobs, :jobs], groups
  end

  def test_replica_crash_restarts_only_that_replica_under_rest_for_one
    sup = build_tree
    capture_events do |events|
      t = Thread.new { sup.run }
      assert wait_until(10) { %i[jobs.1 jobs.2 cron].all? { |i| sup.live_pid(i) } }, "tree should be up"
      Process.kill("KILL", sup.live_pid(:"jobs.1"))
      assert wait_until(10) { spawns(events, :"jobs.1") >= 2 }, "the lost replica should be replaced"
      assert_equal 1, spawns(events, :"jobs.2"), "its peer must not restart"
      assert_equal 1, spawns(events, :cron), "later slots must not restart for a lost replica"
      sup.stop
      assert t.join(10)
    end
  end

  def test_earlier_slot_crash_restarts_the_whole_group_and_later_slots
    sup = build_tree
    capture_events do |events|
      t = Thread.new { sup.run }
      assert wait_until(10) { sup.live_pid(:web) }, "tree should be up"
      Process.kill("KILL", sup.live_pid(:web))
      assert wait_until(10) { spawns(events, :web) >= 2 && spawns(events, :"jobs.1") >= 2 &&
                              spawns(events, :"jobs.2") >= 2 && spawns(events, :cron) >= 2 },
             "an earlier crash under rest_for_one restarts the group and everything after"
      sup.stop
      assert t.join(10)
    end
  end

  def test_control_restart_by_group_name_replaces_every_replica
    Dir.mktmpdir do |dir|
      sup = Odoshi::Supervisor.new(strategy: :one_for_one,
                                   intensity: Odoshi::RestartIntensity.new(max_restarts: 10, within: 60),
                                   backoff: Odoshi::Backoff.new(kind: :none),
                                   socket_path: File.join(dir, "s.sock"))
      %i[jobs.1 jobs.2].each do |id|
        sup.add_child(Odoshi::ChildSpec.new(id: id, adapter: :command, shutdown: 2,
                                            group: :jobs, opts: { cmd: "sleep 30" }))
      end
      capture_events do |events|
        t = Thread.new { sup.run }
        assert wait_until(10) { spawns(events, :"jobs.1") >= 1 && spawns(events, :"jobs.2") >= 1 }
        sock = UNIXSocket.new(File.join(dir, "s.sock"))
        sock.puts({ cmd: "restart", id: "jobs", token: sup.heartbeat_token }.to_json)
        assert wait_until(10) { spawns(events, :"jobs.1") >= 2 && spawns(events, :"jobs.2") >= 2 },
               "restarting the group name must replace every replica"
        sock.close
        sup.stop
        assert t.join(10)
      end
    end
  end

  private

  # web, then a 2-replica jobs group, then cron — rest_for_one.
  def build_tree
    Odoshi.supervise do
      socket nil
      strategy :rest_for_one
      max_restarts 10, within: 60
      backoff :none
      child :web,  adapter: :command, cmd: "sleep 30", shutdown: 2
      child :jobs, adapter: :command, cmd: "sleep 30", shutdown: 2, count: 2
      child :cron, adapter: :command, cmd: "sleep 30", shutdown: 2
    end
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
