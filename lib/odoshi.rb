# frozen_string_literal: true

# odoshi: a slim, Rails-free process supervisor with OTP semantics.
# Nothing under lib/odoshi may require Rails, ActiveSupport, or ActiveRecord (DESIGN §9).
# The Rails-side bridge (railtie) is a later deliverable and is only ever loaded inside children.

require_relative "odoshi/version"

module Odoshi
  class Error < StandardError; end
  class ConfigError < Error; end
  class Escalation < Error; end # raised when restart intensity is exceeded
end

require_relative "odoshi/telemetry"
require_relative "odoshi/child_spec"
require_relative "odoshi/strategy"
require_relative "odoshi/restart_intensity"
require_relative "odoshi/backoff"
require_relative "odoshi/adapter"
require_relative "odoshi/probe"
require_relative "odoshi/orphan_guard"
require_relative "odoshi/adapters/command"
require_relative "odoshi/adapters/puma"
require_relative "odoshi/adapters/solid_queue"
require_relative "odoshi/socket_server"
require_relative "odoshi/heartbeat"
require_relative "odoshi/supervisor"
require_relative "odoshi/adapters/supervisor_adapter" # after supervisor: wraps a child Supervisor
require_relative "odoshi/dsl"
require_relative "odoshi/cli"
