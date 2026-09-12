# frozen_string_literal: true
require "test_helper"
require "tmpdir"

# PLAN 1.1 — shutdown correctness: reverse-order draining, CLI exit codes,
# orphan prevention when the supervisor itself is SIGKILLed.
class ShutdownTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures", __dir__)
  EXE = File.expand_path("../exe/otp-rails", __dir__)

  def test_stop_all_drains_in_reverse_start_order_and_waits_for_each
    Dir.mktmpdir do |dir|
      log = File.join(dir, "events.log")
      sup = OtpRails::Supervisor.new
      %i[a b c].each do |id|
        sup.add_child(OtpRails::ChildSpec.new(id: id, adapter: :command, shutdown: 5,
                                              opts: { cmd: "ruby #{FIXTURES}/term_logger.rb #{id} #{log} 0.3" }))
      end
      t = Thread.new { sup.run }
      assert wait_until(10) { File.exist?(log) && File.readlines(log).count { |l| l.start_with?("UP") } == 3 },
             "all three children should report UP"
      sup.stop
      assert t.join(15), "supervisor should shut down"

      order = File.readlines(log).map(&:split).reject { |tag,| tag == "UP" }.map { |tag, id| "#{tag}:#{id}" }
      assert_equal %w[TERM:c EXIT:c TERM:b EXIT:b TERM:a EXIT:a], order,
                   "stop_all must drain in reverse start order and wait for each child before the next"
    end
  end

  def test_cli_exits_zero_on_clean_stop
    with_config(%(child :a, adapter: :command, cmd: "sleep 30", shutdown: 2)) do |cfg|
      pid = Process.spawn("ruby", EXE, "run", cfg, out: File::NULL, err: File::NULL)
      sleep 1.0
      Process.kill("TERM", pid)
      _, status = Process.wait2(pid)
      assert_equal 0, status.exitstatus, "clean stop must exit 0"
    end
  end

  def test_cli_exits_70_on_escalation
    body = <<~RUBY
      max_restarts 1, within: 60
      backoff :none
      child :crashy, adapter: :command, cmd: "exit 1", shutdown: 1
    RUBY
    with_config(body) do |cfg|
      pid = Process.spawn("ruby", EXE, "run", cfg, out: File::NULL, err: File::NULL)
      _, status = Process.wait2(pid)
      assert_equal 70, status.exitstatus, "escalation must exit 70 (EX_SOFTWARE)"
    end
  end

  def test_children_get_sigterm_when_supervisor_is_sigkilled
    unless OtpRails::OrphanGuard.available?
      skip "orphan prevention needs prctl(PR_SET_PDEATHSIG); unavailable on #{RUBY_PLATFORM} (documented limitation, README)"
    end
    Dir.mktmpdir do |dir|
      pidfile = File.join(dir, "child.pid")
      termfile = File.join(dir, "child.term")
      with_config(%(child :a, adapter: :command, cmd: "ruby #{FIXTURES}/pid_writer.rb #{pidfile} #{termfile}", shutdown: 2)) do |cfg|
        sup_pid = Process.spawn("ruby", EXE, "run", cfg, out: File::NULL, err: File::NULL)
        assert wait_until(10) { File.exist?(pidfile) && !File.read(pidfile).empty? }, "child should write its pid"
        Process.kill("KILL", sup_pid)
        Process.wait2(sup_pid)
        assert wait_until(5) { File.exist?(termfile) },
               "child should receive SIGTERM within 5s of the supervisor being SIGKILLed"
      end
    end
  end

  private

  def with_config(body)
    Dir.mktmpdir do |dir|
      cfg = File.join(dir, "supervisor.rb")
      File.write(cfg, body)
      yield cfg
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
