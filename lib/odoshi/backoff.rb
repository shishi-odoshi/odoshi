# frozen_string_literal: true
module Odoshi
  class Backoff
    def initialize(kind: :exponential, base: 1.0, cap: 30.0)
      @kind, @base, @cap = kind, base.to_f, cap.to_f
    end

    # attempt is 1-based. :exponential follows OTP convention: the FIRST
    # restart is immediate — a one-off crash costs no delay (crash-loops are
    # bounded by restart intensity, and a healthy interval resets attempts) —
    # and the ladder starts at `base` from the second consecutive attempt.
    # :constant stays constant every time: explicit is explicit.
    # (odoshi-template#1: `base: 1` was putting a ~1s floor on every recovery.)
    def delay(attempt)
      case @kind
      when :none        then 0.0
      when :constant    then @base
      when :exponential then attempt <= 1 ? 0.0 : [@base * (2**(attempt - 2)), @cap].min
      else raise ConfigError, "unknown backoff #{@kind}"
      end
    end
  end
end
