# frozen_string_literal: true
require "socket"
require "json"

# Deliberately self-contained (PLAN 1.6): any child process can
#   require "odoshi/heartbeat"
# without loading the rest of the gem — e.g. from a Rails initializer or a
# Solid Queue hook — and never Rails itself (hard rule 1 / DESIGN §9).
module Odoshi
  # Sends DESIGN §5 NDJSON heartbeats to the supervising socket:
  #
  #   beat = Odoshi::Heartbeat.start(id: "jobs")   # => Heartbeat or nil
  #   beat&.stop
  #
  #   Odoshi::Heartbeat.start(id: "jobs", interval: 2,
  #                             state: -> { queue_backlog_ok? ? "healthy" : "degraded" },
  #                             meta:  -> { { backlog: backlog_size } })
  #
  # Silently a no-op (returns nil) when ODOSHI_SOCK / ODOSHI_TOKEN are
  # absent — the child is running unsupervised and that must not be an error.
  #
  # The beating thread is unkillable by bad input (issue #26): a raising
  # state/meta lambda falls back to the last good state / empty meta, an
  # unencodable payload (bad UTF-8) drops down to a bare healthy beat, and
  # socket failures close the socket (issue #29) and retry next beat. Going
  # silent is the one thing this thread must never do while its process is
  # healthy — silence is what gets the child restarted.
  class Heartbeat
    # Returns the Heartbeat (so #stop works — issue #23), or nil when
    # unsupervised.
    def self.start(id:, interval: 2, state: -> { "healthy" }, meta: -> { {} })
      new(id: id, interval: interval, state: state, meta: meta).start
    end

    def initialize(id:, interval: 2, state: -> { "healthy" }, meta: -> { {} })
      @id, @interval, @state, @meta = id.to_s, interval, state, meta
      @sock_path, @token = ENV["ODOSHI_SOCK"], ENV["ODOSHI_TOKEN"]
      @last_state = "healthy"
    end

    def start
      return nil unless @sock_path && @token
      @thread ||= Thread.new { run_loop }
      self
    end

    def stop
      @thread&.kill
      close_socket
    end

    def alive? = !!@thread&.alive?

    private

    def run_loop
      loop do
        begin
          payload = build_payload
          @sock ||= UNIXSocket.new(@sock_path)
          @sock.puts(payload)
        rescue StandardError
          close_socket # supervisor gone or restarting; reconnect next beat
        end
        sleep @interval
      end
    end

    def build_payload
      state = safe_state
      meta = begin
        @meta.call
      rescue StandardError
        {}
      end
      encode(state, meta) || encode(state, {}) || encode("healthy", {})
    end

    def safe_state
      @last_state = @state.call.to_s
    rescue StandardError
      @last_state
    end

    def encode(state, meta)
      JSON.generate(id: @id, state: state, ts: Time.now.to_i, token: @token, meta: meta)
    rescue StandardError
      nil
    end

    def close_socket
      @sock&.close
      @sock = nil
    rescue IOError, SystemCallError
      @sock = nil
    end
  end
end
