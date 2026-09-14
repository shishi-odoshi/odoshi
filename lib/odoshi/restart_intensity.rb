# frozen_string_literal: true
module Odoshi
  # OTP restart intensity: more than `max_restarts` within `within` seconds => escalate.
  class RestartIntensity
    attr_reader :max_restarts, :within

    def initialize(max_restarts: 5, within: 60, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @max_restarts, @within, @clock = max_restarts, within, clock
      @events = []
    end

    # Records a restart. Returns true if the supervisor should escalate (give up).
    def record!
      now = @clock.call
      @events << now
      @events.reject! { |t| now - t > @within }
      @events.size > @max_restarts
    end

    def count = @events.size
  end
end
