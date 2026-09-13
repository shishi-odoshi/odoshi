# frozen_string_literal: true
require "test_helper"
require "socket"
require "json"
require "tmpdir"

# QA #23/#26/#29 — the Heartbeat helper as a client library: usable API,
# unkillable beat thread, no fd leaks across supervisor outages.
class HeartbeatTest < Minitest::Test
  def test_start_returns_the_instance_and_stop_ends_the_thread
    with_server do |_dir, _server, _lines|
      beat = OtpRails::Heartbeat.start(id: "x", interval: 0.05)
      assert_kind_of OtpRails::Heartbeat, beat, "start must return the Heartbeat (issue #23)"
      assert beat.alive?
      beat.stop
      assert wait_until(5) { !beat.alive? }, "stop must end the beating thread"
    end
  end

  def test_raising_state_lambda_falls_back_to_last_good_state_and_keeps_beating
    with_server do |_dir, _server, lines|
      calls = 0
      beat = OtpRails::Heartbeat.start(id: "x", interval: 0.05,
                                       state: -> { (calls += 1) == 3 ? raise("boom") : "degraded" })
      assert wait_until(10) { lines.size >= 5 }, "the thread must survive a raising state lambda (issue #26)"
      states = lines.map { |l| JSON.parse(l)["state"] }.uniq
      assert_equal ["degraded"], states, "the raising call must fall back to the last good state"
      beat.stop
    end
  end

  def test_unencodable_meta_degrades_to_empty_meta_and_keeps_beating
    with_server do |_dir, _server, lines|
      bad = (+"\xff\xfe").force_encoding("UTF-8") # unencodable by JSON
      beat = OtpRails::Heartbeat.start(id: "x", interval: 0.05, meta: -> { { junk: bad } })
      assert wait_until(10) { lines.size >= 3 }, "the thread must survive unencodable meta (issue #26)"
      assert_equal [{}], lines.map { |l| JSON.parse(l)["meta"] }.uniq, "bad meta is dropped, the beat is not"
      beat.stop
    end
  end

  def test_no_fd_leak_while_the_supervisor_is_away
    Dir.mktmpdir do |dir|
      path = File.join(dir, "s.sock")
      with_env(path) do
        beat = OtpRails::Heartbeat.start(id: "x", interval: 0.01) # nothing listening at all
        sleep 0.3 # ~30 failed connect/beat cycles
        before = fd_count
        sleep 1.0 # ~100 more
        after = fd_count
        assert_operator (after - before).abs, :<=, 4,
                        "failed beats must not accumulate fds (issue #29): #{before} -> #{after}"
        beat.stop
      end
    end
  end

  private

  def with_server
    Dir.mktmpdir do |dir|
      path = File.join(dir, "s.sock")
      server = UNIXServer.new(path)
      lines = []
      accepter = Thread.new do
        loop do
          conn = server.accept
          Thread.new { conn.each_line { |l| lines << l } rescue nil }
        rescue IOError
          break
        end
      end
      with_env(path) { yield dir, server, lines }
    ensure
      server&.close
      accepter&.kill
    end
  end

  def with_env(path)
    old = [ENV["OTP_RAILS_SOCK"], ENV["OTP_RAILS_TOKEN"]]
    ENV["OTP_RAILS_SOCK"], ENV["OTP_RAILS_TOKEN"] = path, "test-token"
    yield
  ensure
    ENV["OTP_RAILS_SOCK"], ENV["OTP_RAILS_TOKEN"] = old
  end

  def fd_count = Dir["/dev/fd/*"].size

  def wait_until(timeout)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
    true
  end
end
