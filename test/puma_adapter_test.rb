# frozen_string_literal: true
require "test_helper"
require "net/http"
require "socket"
require "tmpdir"

# PLAN 1.5 — :puma adapter, beside mode (DESIGN §4.2 step 1). Real puma
# (test-only dependency), real kill -9 of the master, no mocks.
class PumaAdapterTest < Minitest::Test
  include TelemetryCapture

  RACK_APP = File.expand_path("fixtures/rack_app", __dir__)
  # Puma boots in well under a second; deadlines are generous, not load-bearing.
  WAIT = 20

  def test_puma_child_becomes_healthy_restarts_after_master_kill_and_up_answers_again
    port = free_port
    sup = build_sup(config: "#{RACK_APP}/puma.rb", port: port,
                    env: { "PUMA_TEST_PORT" => port.to_s })
    capture_events do |events|
      t = Thread.new { sup.run }
      assert wait_until(WAIT) { healthy_count(events) >= 1 }, "puma should become :healthy (telemetry child.healthy)"
      assert wait_until(WAIT) { up?(port) }, "/up should answer 200 once :healthy"

      Process.kill("KILL", sup.live_pid(:web))
      assert wait_until(WAIT) { spawns(events, :web) >= 2 }, "killed puma master should be respawned"
      assert wait_until(WAIT) { healthy_count(events) >= 2 }, "respawned puma should become :healthy"
      assert wait_until(WAIT) { up?(port) }, "/up should answer again after the restart"

      sup.stop
      assert t.join(WAIT), "supervisor should stop cleanly"
      refute up?(port), "puma should be gone after a clean stop"
    end
  end

  def test_port_is_parsed_from_a_literal_port_line_in_the_config_file
    port = free_port
    Dir.mktmpdir do |dir|
      config = File.join(dir, "puma.rb")
      File.write(config, <<~RUBY)
        rackup "#{RACK_APP}/config.ru"
        port #{port}, "127.0.0.1"
      RUBY
      sup = build_sup(config: config) # no opts[:port]: must come from the file
      capture_events do |events|
        t = Thread.new { sup.run }
        assert wait_until(WAIT) { healthy_count(events) >= 1 },
               "adapter should parse `port #{port}` from the config file and see /up"
        assert up?(port)
        sup.stop
        assert t.join(WAIT), "supervisor should stop cleanly"
      end
    end
  end

  def test_no_port_anywhere_raises_config_error_before_spawning
    spec = Odoshi::ChildSpec.new(id: :web, adapter: :puma,
                                   opts: { config: "#{RACK_APP}/puma.rb" }) # env-var port, no literal line
    err = assert_raises(Odoshi::ConfigError) { Odoshi::Adapter.lookup(:puma).new.spawn(spec) }
    assert_match(/port/, err.message)
  end

  private

  def build_sup(**opts)
    sup = Odoshi::Supervisor.new(strategy: :one_for_one,
                                   intensity: Odoshi::RestartIntensity.new(max_restarts: 5, within: 60),
                                   backoff: Odoshi::Backoff.new(kind: :none))
    sup.add_child(Odoshi::ChildSpec.new(
                    id: :web, adapter: :puma, shutdown: 10, start_timeout: WAIT,
                    opts: { spawn_opts: { out: File::NULL, err: File::NULL } }.merge(opts)
                  ))
    sup
  end

  # Independent check (plain Net::HTTP, not the adapter's probe).
  def up?(port)
    Net::HTTP.start("127.0.0.1", port, open_timeout: 0.5, read_timeout: 1) do |http|
      http.get("/up").code == "200"
    end
  rescue SystemCallError, IO::TimeoutError, Net::OpenTimeout, Net::ReadTimeout, EOFError
    false
  end

  def healthy_count(events, id = :web)
    events.count { |e| e[:event].last == :healthy && e[:metadata][:id] == id }
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
