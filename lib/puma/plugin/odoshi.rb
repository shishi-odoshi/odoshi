# frozen_string_literal: true
# Puma plugin (DESIGN §4.2 step 2, PLAN 2.5): worker-level visibility for a
# :puma child, over the §5 heartbeat socket. Enable with `plugin :odoshi`
# in config/puma.rb.
#
# Lives under lib/puma/ (NOT lib/odoshi/) because it may require puma —
# it is only ever loaded BY puma, so hard rule 1 (the supervisor has zero
# dependencies) holds. It reuses the frozen heartbeat protocol untouched:
# worker detail travels in `state` and `meta`, never in new fields.
#
# The master heartbeats every ODOSHI_HEARTBEAT_INTERVAL (default 2s). The
# reported state is the WORSE of two views (issue #49 — a heartbeat must
# never vouch for an app its own health endpoint says is sick, because
# active heartbeats out-vote passive probes in the supervisor's §5
# active-first health):
#   - worker topology: "degraded" while any worker is missing (booted <
#     configured); single mode has no workers to count;
#   - app health: /up probed on the first tcp bind — "starting" until the
#     first 2xx, "degraded" if it stops answering 2xx afterwards.
#   meta = { workers:, booted:, phase: } (cluster) | { mode: "single" },
#   plus up: true/false once a tcp bind is probeable.
# ODOSHI_HEALTH_URL overrides the probe URL (e.g. unix-socket binds);
# with no tcp bind and no override, state falls back to topology only.
# The supervisor turns a reported "degraded" into [:odoshi, :child,
# :degraded] telemetry via its normal health loop — no event added, and no
# lifecycle change: puma still replaces its own workers.
require "puma/plugin"
require "odoshi/heartbeat"
require "odoshi/probe"

Puma::Plugin.create do
  HEALTH_PATH = "/up"

  def start(launcher)
    beat = Odoshi::Heartbeat.start(
      id: ENV["ODOSHI_CHILD_ID"] || "web",
      interval: Float(ENV.fetch("ODOSHI_HEARTBEAT_INTERVAL", 2)),
      state: -> { odoshi_state(launcher) },
      meta: -> { odoshi_meta(launcher) }
    )
    launcher.events.on_stopped { beat.stop } if beat
  end

  private

  # Raising inside the heartbeat thread would silently kill it, so both
  # lambdas degrade to a safe value instead (stats can raise mid-boot).
  def odoshi_state(launcher)
    stats = launcher.stats
    worker_missing = stats[:workers] && stats[:booted_workers] < stats[:workers]
    return "degraded" if worker_missing
    case odoshi_up_state(launcher)
    when :down then "degraded"
    when :booting then "starting"
    else "healthy"
    end
  rescue StandardError
    "starting"
  end

  def odoshi_meta(launcher)
    stats = launcher.stats
    meta = stats[:workers] ? { workers: stats[:workers], booted: stats[:booted_workers], phase: stats[:phase] } : { mode: "single" }
    up = odoshi_up_state(launcher)
    meta[:up] = (up == :up) unless up == :unprobeable
    meta
  rescue StandardError
    {}
  end

  # :up | :down | :booting (no 2xx yet) | :unprobeable (no tcp bind, no override)
  def odoshi_up_state(launcher)
    url = odoshi_health_url(launcher)
    return :unprobeable unless url
    if Odoshi::Probe.http?(url)
      @odoshi_up_once = true
      :up
    else
      @odoshi_up_once ? :down : :booting
    end
  end

  def odoshi_health_url(launcher)
    return @odoshi_health_url if defined?(@odoshi_health_url)
    @odoshi_health_url =
      if (override = ENV["ODOSHI_HEALTH_URL"]) && !override.empty?
        override
      elsif (bind = Array(launcher.options[:binds]).find { |b| b.start_with?("tcp://") })
        # tcp://host:port — probe loopback on the bound port ("0.0.0.0" isn't a
        # connectable address)
        port = bind.split(":").last.to_i
        "http://127.0.0.1:#{port}#{HEALTH_PATH}"
      end
  end
end
