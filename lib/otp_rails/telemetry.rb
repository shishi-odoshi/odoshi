# frozen_string_literal: true
require "json"

module OtpRails
  # Minimal event bus. Event names mirror Elixir :telemetry (DESIGN §6):
  #   event: [:otp_rails, :child, :restart], measurements: {...}, metadata: {...}
  # A railtie will bridge these into ActiveSupport::Notifications inside children.
  module Telemetry
    EVENTS = %i[
      supervisor.start supervisor.stop supervisor.escalate
      child.spawn child.healthy child.degraded child.exit child.restart child.drain child.kill
    ].freeze

    @subscribers = []
    @mutex = Mutex.new

    class << self
      def subscribe(&block)
        @mutex.synchronize { @subscribers << block }
        block
      end

      def unsubscribe(block)
        @mutex.synchronize { @subscribers.delete(block) }
      end

      def reset!
        @mutex.synchronize { @subscribers.clear }
      end

      # name: Symbol like :"child.restart" (flat in Ruby; split on "." for the Elixir side)
      def emit(name, measurements = {}, metadata = {})
        raise ArgumentError, "unknown event #{name}" unless EVENTS.include?(name)
        event = { event: [:otp_rails, *name.to_s.split(".").map(&:to_sym)],
                  measurements: measurements, metadata: metadata,
                  ts: Process.clock_gettime(Process::CLOCK_REALTIME) }
        subs = @mutex.synchronize { @subscribers.dup }
        subs.each { |s| s.call(event) }
        event
      end
    end

    # Default subscribers shipped in v0.1
    module Subscribers
      def self.logger(io = $stderr)
        Telemetry.subscribe do |e|
          io.puts("[otp-rails] #{e[:event].join('.')} #{e[:metadata].inspect} #{e[:measurements].inspect}")
        end
      end

      def self.json_lines(io = $stdout)
        Telemetry.subscribe { |e| io.puts(JSON.generate(e)) }
      end
    end
  end
end
