# frozen_string_literal: true
module OtpRails
  module Adapters
    # DESIGN §4.1 / §9 — :solid_queue wraps the Solid Queue supervisor
    # (`bin/jobs`). Health is the ACTIVE heartbeat (§5), NOT the
    # solid_queue_processes table: the app sends heartbeats via the tiny
    # Rails-free hook, e.g. from an initializer:
    #
    #   require "otp_rails/heartbeat"
    #   OtpRails::Heartbeat.start(id: "jobs")
    #
    # Once the first heartbeat arrives the supervisor judges the child by
    # heartbeat freshness (3 missed intervals ⇒ :degraded, 6 ⇒ :dead);
    # until then it falls back to this adapter's passive PID health,
    # inherited from Command — as are link, drain (SIGTERM, which Solid
    # Queue handles gracefully), and kill.
    #
    # opts:
    #   cmd:  the jobs command (default "bin/jobs")
    #   env:, spawn_opts:  passed through to Command verbatim.
    class SolidQueue < Command
      DEFAULT_CMD = "bin/jobs"

      def spawn(spec)
        super(command_spec(spec))
      end

      private

      def command_spec(spec)
        ChildSpec.new(
          id: spec.id, adapter: spec.adapter, restart: spec.restart,
          shutdown: spec.shutdown, start_timeout: spec.start_timeout,
          opts: spec.opts.merge(
            cmd: spec.opts.fetch(:cmd, DEFAULT_CMD),
            # Tag the child so the Heartbeat hook picks up its id from env;
            # explicit env still wins.
            env: { "OTP_RAILS_CHILD_ID" => spec.id.to_s }.merge(spec.opts.fetch(:env, {}))
          )
        )
      end
    end
  end
  Adapter.register(:solid_queue, Adapters::SolidQueue)
end
