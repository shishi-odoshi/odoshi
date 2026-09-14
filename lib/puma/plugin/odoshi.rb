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
# The master heartbeats every ODOSHI_HEARTBEAT_INTERVAL (default 2s):
#   state = "degraded" while any worker is missing (booted < configured),
#           "healthy" otherwise (single mode is always "healthy"),
#   meta  = { workers:, booted:, phase: } (cluster) | { mode: "single" }.
# The supervisor turns a reported "degraded" into [:odoshi, :child,
# :degraded] telemetry via its normal health loop — no event added, and no
# lifecycle change: puma still replaces its own workers.
require "puma/plugin"
require "odoshi/heartbeat"

Puma::Plugin.create do
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
    return "healthy" unless stats[:workers] # single mode
    stats[:booted_workers] < stats[:workers] ? "degraded" : "healthy"
  rescue StandardError
    "starting"
  end

  def odoshi_meta(launcher)
    stats = launcher.stats
    return { mode: "single" } unless stats[:workers]
    { workers: stats[:workers], booted: stats[:booted_workers], phase: stats[:phase] }
  rescue StandardError
    {}
  end
end
