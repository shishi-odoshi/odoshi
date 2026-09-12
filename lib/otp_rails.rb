# frozen_string_literal: true

# otp-rails: a slim, Rails-free process supervisor with OTP semantics.
# Nothing under lib/otp_rails may require Rails, ActiveSupport, or ActiveRecord (DESIGN §9).
# The Rails-side bridge (railtie) is a later deliverable and is only ever loaded inside children.

require_relative "otp_rails/version"

module OtpRails
  class Error < StandardError; end
  class ConfigError < Error; end
  class Escalation < Error; end # raised when restart intensity is exceeded
end

require_relative "otp_rails/telemetry"
require_relative "otp_rails/child_spec"
require_relative "otp_rails/strategy"
require_relative "otp_rails/restart_intensity"
require_relative "otp_rails/backoff"
require_relative "otp_rails/adapter"
require_relative "otp_rails/probe"
require_relative "otp_rails/orphan_guard"
require_relative "otp_rails/adapters/command"
require_relative "otp_rails/adapters/puma"
require_relative "otp_rails/socket_server"
require_relative "otp_rails/supervisor"
require_relative "otp_rails/dsl"
require_relative "otp_rails/cli"
