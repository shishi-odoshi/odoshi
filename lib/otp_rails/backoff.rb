# frozen_string_literal: true
module OtpRails
  class Backoff
    def initialize(kind: :exponential, base: 1.0, cap: 30.0)
      @kind, @base, @cap = kind, base.to_f, cap.to_f
    end

    # attempt is 1-based
    def delay(attempt)
      case @kind
      when :none        then 0.0
      when :constant    then @base
      when :exponential then [@base * (2**(attempt - 1)), @cap].min
      else raise ConfigError, "unknown backoff #{@kind}"
      end
    end
  end
end
