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

  # Issue #16/#27: valid-token heartbeats for ids that match no child must be
  # dropped at intake, not hoarded forever.
  def test_heartbeats_for_unknown_ids_are_dropped
    Dir.mktmpdir do |dir|
      with_sup(dir, cmd: "sleep 30") do |sup, _events|
        sock = UNIXSocket.new(File.join(dir, "s.sock"))
        50.times { |i| sock.puts({ id: "ghost#{i}", state: "healthy", ts: 0, token: sup.heartbeat_token, meta: {} }.to_json) }
        sock.puts({ id: "hb", state: "healthy", ts: 0, token: sup.heartbeat_token, meta: {} }.to_json)
        assert wait_until(10) { heartbeat_active?(sup) }, "the real child's heartbeat still lands"
        assert_equal [:hb], sup.instance_variable_get(:@heartbeats).keys, "ghost ids must not be recorded"
        sock.close
      end
    end
  end

  # Issue #27: an over-long line is malformed — capped in memory, discarded,
  # and the connection keeps working afterwards.
  def test_oversized_lines_are_dropped_and_the_connection_survives
    Dir.mktmpdir do |dir|
      with_sup(dir, cmd: "sleep 30") do |sup, _events|
        sock = UNIXSocket.new(File.join(dir, "s.sock"))
        sock.write("x" * (500 * 1024)); sock.write("\n")
        sock.puts({ id: "hb", state: "healthy", ts: 0, token: sup.heartbeat_token, meta: {} }.to_json)
        assert wait_until(10) { heartbeat_active?(sup) },
               "a valid heartbeat after a 500KB junk line must still be processed"
        sock.close
      end
    end
  end

  # Issue #27: non-string id/state/cmd are malformed — dropped without killing
  # the connection thread (or dispatching bogus control).
  def test_non_string_fields_are_dropped_and_the_connection_survives
    Dir.mktmpdir do |dir|
      with_sup(dir, cmd: "sleep 30") do |sup, events|
        sock = UNIXSocket.new(File.join(dir, "s.sock"))
        sock.puts({ id: 123, state: "healthy", ts: 0, token: sup.heartbeat_token }.to_json)
        sock.puts({ id: "hb", state: { nested: true }, ts: 0, token: sup.heartbeat_token }.to_json)
        sock.puts({ cmd: false, id: "hb", token: sup.heartbeat_token }.to_json)
        sock.puts({ cmd: "restart", id: 42, token: sup.heartbeat_token }.to_json)
        sleep 0.5
        refute heartbeat_active?(sup), "malformed heartbeats must not be recorded"
        assert_equal 1, spawns(events, :hb), "malformed control must not restart anything"
        sock.puts({ id: "hb", state: "healthy", ts: 0, token: sup.heartbeat_token, meta: {} }.to_json)
        assert wait_until(10) { heartbeat_active?(sup) }, "the connection must survive malformed lines"
        sock.close
      end
    end
  end

  # Issue #25: a heartbeat naming a child with health_interval: nil (subtree
  # specs) crashed the whole tree with a nil division. It must be judged
  # passively instead.
  def test_heartbeat_for_nil_interval_child_does_not_crash_the_tree
    Dir.mktmpdir do |dir|
      sup = OtpRails::Supervisor.new(socket_path: File.join(dir, "s.sock"))
      sup.add_child(OtpRails::ChildSpec.new(id: :quiet, adapter: :command, shutdown: 2,
                                            health_interval: nil, opts: { cmd: "sleep 30" }))
      capture_events do |events|
        t = Thread.new { sup.run }
        assert wait_until(10) { spawns(events, :quiet) >= 1 }, "child should start"
        sock = UNIXSocket.new(File.join(dir, "s.sock"))
        sock.puts({ id: "quiet", state: "healthy", ts: 0, token: sup.heartbeat_token, meta: {} }.to_json)
        sleep 0.6
        assert t.alive?, "a heartbeat for a nil-interval child must not crash the supervisor"
        sock.puts({ cmd: "restart", id: "quiet", token: sup.heartbeat_token }.to_json)
        assert wait_until(10) { spawns(events, :quiet) >= 2 }, "tree must still be fully operational"
        sock.close
        sup.stop
        assert t.join(10), "supervisor should stop cleanly"
      end
    end
  end

  # Issue #31: an unusable socket path is a config problem (exit 78), not a
  # raw ArgumentError stacktrace.
  def test_unusable_socket_path_raises_config_error
    sup = OtpRails::Supervisor.new(socket_path: "/tmp/#{"x" * 300}/s.sock")
    sup.add_child(OtpRails::ChildSpec.new(id: :a, adapter: :command, opts: { cmd: "sleep 1" }))
    assert_raises(OtpRails::ConfigError) { sup.run }
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
