# frozen_string_literal: true
module OtpRails
  # DESIGN §3.2
  class ChildSpec
    RESTART_KINDS = %i[permanent transient temporary].freeze

    attr_reader :id, :adapter, :restart, :shutdown, :start_timeout, :health_interval,
                :degraded_restart_after, :opts

    def initialize(id:, adapter:, restart: :permanent, shutdown: 30, start_timeout: 30,
                   health_interval: 5, degraded_restart_after: nil, opts: {})
      raise ConfigError, "child id must be a Symbol" unless id.is_a?(Symbol)
      raise ConfigError, "restart must be one of #{RESTART_KINDS}" unless RESTART_KINDS.include?(restart)
      @id, @adapter, @restart, @shutdown, @start_timeout, @opts =
        id, adapter, restart, shutdown, start_timeout, opts
      @health_interval, @degraded_restart_after = health_interval, degraded_restart_after
    end

    # Should this child be restarted given how it exited? (OTP semantics)
    def restart?(exit_status)
      case restart
      when :permanent then true
      when :transient then !normal_exit?(exit_status)
      when :temporary then false
      end
    end

    def normal_exit?(status)
      return false if status.nil?
      status.respond_to?(:success?) ? status.success? : status.to_i.zero?
    end
  end
end
