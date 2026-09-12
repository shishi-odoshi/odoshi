# frozen_string_literal: true
module OtpRails
  # DESIGN §4. Exactly four operations (+ kill as last resort). Adapters never talk to each other.
  class Adapter
    REGISTRY = {}

    def self.register(name, klass) = REGISTRY[name] = klass
    def self.lookup(name) = REGISTRY.fetch(name) { raise ConfigError, "no adapter registered as #{name.inspect}" }

    # @return [Object] opaque handle
    def spawn(spec) = raise NotImplementedError
    # Register a one-shot callback: block.call(exit_status)
    def link(handle, &on_exit) = raise NotImplementedError
    # @return [:starting, :healthy, :degraded, :dead]
    def health(handle) = raise NotImplementedError
    # Stop accepting work, finish in-flight, exit. Return true if exited within timeout.
    def drain(handle, timeout:) = raise NotImplementedError
    # Last resort after drain times out.
    def kill(handle) = raise NotImplementedError
  end
end
