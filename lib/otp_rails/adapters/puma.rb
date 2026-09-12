# frozen_string_literal: true
module OtpRails
  module Adapters
    # DESIGN §4.1 / §4.2 step 1 — :puma in "beside" mode: one opaque child
    # wrapping the puma master. Health = HTTP probe of /up (the Rails 7.1+
    # default endpoint) on the bound port; drain = SIGTERM, which is Puma's
    # graceful shutdown — exactly Command#drain, so it is inherited unchanged,
    # as are link and kill.
    #
    # The whole adapter is Command with a derived spec: spawn builds the puma
    # command line and injects a probe: { http: ".../up" } opt, so health()
    # rides the PLAN 1.2 Probe path with no new code — :starting until /up
    # answers 2xx, then :healthy; :dead when the PID goes.
    #
    # opts:
    #   config:     puma config file path (default "config/puma.rb")
    #   port:       the bound port. When absent, a literal `port NNNN` line is
    #               parsed from the config file; neither ⇒ ConfigError.
    #   env:, spawn_opts:  passed through to Command verbatim.
    #   (cmd: and probe: are owned by this adapter and overwritten.)
    class Puma < Command
      DEFAULT_CONFIG = "config/puma.rb"
      HEALTH_PATH = "/up"

      def spawn(spec)
        super(command_spec(spec))
      end

      private

      def command_spec(spec)
        config = spec.opts.fetch(:config, DEFAULT_CONFIG)
        port = resolve_port(spec, config)
        ChildSpec.new(
          id: spec.id, adapter: spec.adapter, restart: spec.restart,
          shutdown: spec.shutdown, start_timeout: spec.start_timeout,
          opts: spec.opts.merge(
            cmd: "bundle exec puma -C #{config}",
            probe: { http: "http://127.0.0.1:#{port}#{HEALTH_PATH}" }
          )
        )
      end

      # opts[:port] wins; else a literal `port NNNN` line in the config file.
      # Anything fancier (ENV/ERB in the config) must pass opts[:port].
      def resolve_port(spec, config)
        return Integer(spec.opts[:port]) if spec.opts[:port]
        literal = File.file?(config) && File.read(config)[/^\s*port\s+(\d+)/, 1]
        return Integer(literal) if literal
        raise ConfigError,
              "#{spec.id}: :puma needs opts[:port] or a literal `port NNNN` line in #{config}"
      end
    end
  end
  Adapter.register(:puma, Adapters::Puma)
end
