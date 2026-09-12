# frozen_string_literal: true
require "socket"
require "json"

# Deliberately self-contained (PLAN 1.6): any child process can
#   require "otp_rails/heartbeat"
# without loading the rest of the gem — e.g. from a Rails initializer or a
# Solid Queue hook — and never Rails itself (hard rule 1 / DESIGN §9).
module OtpRails
  # Sends DESIGN §5 NDJSON heartbeats to the supervising socket:
  #
  #   OtpRails::Heartbeat.start(id: "jobs")
  #   OtpRails::Heartbeat.start(id: "jobs", interval: 2,
  #                             state: -> { queue_backlog_ok? ? "healthy" : "degraded" },
  #                             meta:  -> { { backlog: backlog_size } })
  #
  # Silently a no-op when OTP_RAILS_SOCK / OTP_RAILS_TOKEN are absent — the
  # child is running unsupervised (plain `bin/jobs` in development) and that
  # must not be an error. Reconnects on socket loss; never raises into the
  # host process.
  class Heartbeat
    def self.start(id:, interval: 2, state: -> { "healthy" }, meta: -> { {} })
      new(id: id, interval: interval, state: state, meta: meta).start
    end

    def initialize(id:, interval: 2, state: -> { "healthy" }, meta: -> { {} })
      @id, @interval, @state, @meta = id.to_s, interval, state, meta
      @sock_path, @token = ENV["OTP_RAILS_SOCK"], ENV["OTP_RAILS_TOKEN"]
    end

    # Returns the beating thread, or nil when unsupervised.
    def start
      return nil unless @sock_path && @token
      @thread = Thread.new do
        sock = nil
        loop do
          begin
            sock ||= UNIXSocket.new(@sock_path)
            sock.puts(JSON.generate(id: @id, state: @state.call, ts: Time.now.to_i,
                                    token: @token, meta: @meta.call))
          rescue IOError, SystemCallError
            sock = nil # supervisor gone or restarting; try again next beat
          end
          sleep @interval
        end
      end
    end

    def stop = @thread&.kill
  end
end
