# frozen_string_literal: true
require "test_helper"
require "socket"
require "json"
require "tmpdir"
require "fileutils"

# PLAN 1.4 — active heartbeat socket: NDJSON heartbeats mark a child active;
# 3 missed intervals ⇒ :degraded, 6 ⇒ :dead ⇒ strategy; bad tokens are
# dropped; {"cmd":"restart"} on the same socket restarts a child.
class SocketTest < Minitest::Test
  include TelemetryCapture

  FIXTURES = File.expand_path("fixtures", __dir__)

  def test_child_that_stops_heartbeating_is_degraded_then_restarted
    Dir.mktmpdir do |dir|
      flag = File.join(dir, "stop.flag")
      with_sup(dir, cmd: "ruby #{FIXTURES}/heartbeater.rb 0.1 #{flag}") do |sup, events|
        assert_equal 0o600, File.stat(File.join(dir, "s.sock")).mode & 0o777, "socket must be mode 0600"
        assert wait_until(10) { heartbeat_active?(sup) }, "supervisor should have recorded a heartbeat"
        FileUtils.touch(flag) # child goes silent but stays alive
        assert wait_until(10) { degraded(events).any? }, "3 missed intervals should emit :degraded"
        assert wait_until(10) { spawns(events, :hb) >= 2 },
               "6 missed intervals should count as :dead and restart the child"
      end
    end
  end

  def test_heartbeats_with_bad_token_are_dropped
    Dir.mktmpdir do |dir|
      with_sup(dir, cmd: "ruby #{FIXTURES}/bad_heartbeater.rb") do |sup, events|
        sleep 1.5 # six health intervals — plenty for a wrongly-accepted heartbeat to age into :dead
        assert_equal 1, spawns(events, :hb), "a bad-token heartbeat must not make the child active"
        assert_empty degraded(events), "a dropped heartbeat must not produce degraded reports"
        refute heartbeat_active?(sup), "the heartbeat must not be recorded"
      end
    end
  end

  def test_control_restart_message_restarts_child_and_bad_token_is_ignored
    Dir.mktmpdir do |dir|
      with_sup(dir, cmd: "sleep 30") do |sup, events|
        sock = UNIXSocket.new(File.join(dir, "s.sock"))
        sock.puts({ cmd: "restart", id: "hb", token: "wrong-token" }.to_json)
        sleep 0.5
        assert_equal 1, spawns(events, :hb), "a bad-token control message must be ignored"
        sock.puts({ cmd: "restart", id: "hb", token: sup.heartbeat_token }.to_json)
        assert wait_until(10) { spawns(events, :hb) >= 2 }, "restart command should replace the child"
        assert events.any? { |e| e[:event].last == :drain && e[:metadata][:id] == :hb },
               "the old child should have been drained"
        sock.close
      end
    end
  end

  private

  def with_sup(dir, cmd:)
    sup = OtpRails::Supervisor.new(strategy: :one_for_one,
                                   intensity: OtpRails::RestartIntensity.new(max_restarts: 10, within: 60),
                                   backoff: OtpRails::Backoff.new(kind: :none),
                                   socket_path: File.join(dir, "s.sock"))
    sup.add_child(OtpRails::ChildSpec.new(id: :hb, adapter: :command, shutdown: 2, start_timeout: 10,
                                          health_interval: 0.2, opts: { cmd: cmd }))
    capture_events do |events|
      t = Thread.new { sup.run }
      assert wait_until(10) { spawns(events, :hb) >= 1 }, "child should start"
      yield sup, events
      sup.stop
      assert t.join(10), "supervisor should stop cleanly"
    end
  end

  def heartbeat_active?(sup)
    sup.instance_variable_get(:@heartbeats).key?(:hb)
  end

  def degraded(events)
    events.select { |e| e[:event].last == :degraded && e[:metadata][:id] == :hb }
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
