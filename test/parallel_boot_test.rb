# frozen_string_literal: true
require "test_helper"
require "socket"
require "tmpdir"

# 0.4.0 P2 — parallelism where ordering doesn't bind: one_for_one trees boot
# concurrently (max, not Σ), replica groups start and drain together, and
# ordered strategies keep their serial slot contract.
class ParallelBootTest < Minitest::Test
  include TelemetryCapture

  FIXTURES = File.expand_path("fixtures", __dir__)

  # Three children each needing ~0.8s to answer their probe: serial boot is
  # ≥2.4s, concurrent is ~0.8s. The 1.9s line cleanly separates the two even
  # on a loaded machine.
  def test_one_for_one_tree_boots_concurrently
    ports = Array.new(3) { free_port }
    sup = Odoshi::Supervisor.new
    ports.each_with_index do |port, i|
      sup.add_child(Odoshi::ChildSpec.new(id: :"slow#{i}", adapter: :command, shutdown: 2, start_timeout: 15,
                                          opts: { cmd: "ruby #{FIXTURES}/tcp_server.rb #{port} 0.8",
                                                  probe: { tcp: port } }))
    end
    capture_events do |events|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      t = Thread.new { sup.run }
      assert wait_until(15) { events.count { |e| e[:event].last == :healthy } == 3 },
             "all three children should become healthy"
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_operator elapsed, :<, 1.9,
                      "one_for_one boot must be concurrent (max ~0.8s), was #{elapsed.round(2)}s (serial would be ≥2.4s)"
      sup.stop
      assert t.join(10)
    end
  end

  def test_rest_for_one_boot_stays_ordered
    log_order = []
    port1, port2 = free_port, free_port
    sup = Odoshi::Supervisor.new(strategy: :rest_for_one)
    sup.add_child(Odoshi::ChildSpec.new(id: :first, adapter: :command, shutdown: 2, start_timeout: 15,
                                        opts: { cmd: "ruby #{FIXTURES}/tcp_server.rb #{port1} 0.5", probe: { tcp: port1 } }))
    sup.add_child(Odoshi::ChildSpec.new(id: :second, adapter: :command, shutdown: 2, start_timeout: 15,
                                        opts: { cmd: "ruby #{FIXTURES}/tcp_server.rb #{port2} 0.1", probe: { tcp: port2 } }))
    capture_events do |events|
      t = Thread.new { sup.run }
      assert wait_until(15) { events.count { |e| e[:event].last == :healthy } == 2 }
      healthy_order = events.select { |e| e[:event].last == :healthy }.map { |e| e[:metadata][:id] }
      assert_equal %i[first second], healthy_order,
                   "declaration order is the dependency contract under rest_for_one: " \
                   ":second must not even spawn until :first is healthy"
      spawn_of_second = events.index { |e| e[:event].last == :spawn && e[:metadata][:id] == :second }
      healthy_of_first = events.index { |e| e[:event].last == :healthy && e[:metadata][:id] == :first }
      assert_operator healthy_of_first, :<, spawn_of_second, "slot 2 spawns only after slot 1 is healthy"
      sup.stop
      assert t.join(10)
    end
  end

  # Three replicas each lingering 0.5s on TERM: serial drain ≥1.5s,
  # concurrent ~0.5s.
  def test_replica_group_drains_concurrently_on_stop
    Dir.mktmpdir do |dir|
      log = File.join(dir, "events.log")
      sup = Odoshi.supervise do
        socket nil
        child :lingerer, adapter: :command, shutdown: 5, count: 3,
                         cmd: "ruby #{File.expand_path("fixtures", __dir__)}/term_logger.rb x #{log} 0.5"
      end
      t = Thread.new { sup.run }
      assert wait_until(10) { File.exist?(log) && File.readlines(log).count { |l| l.start_with?("UP") } == 3 }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sup.stop
      assert t.join(10), "supervisor should stop"
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_operator elapsed, :<, 1.2,
                      "3 replicas × 0.5s linger must drain concurrently, was #{elapsed.round(2)}s (serial ≥1.5s)"
      assert_equal 3, File.readlines(log).count { |l| l.start_with?("EXIT") }, "every replica drained cleanly"
    end
  end

  private

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
