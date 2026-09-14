# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "odoshi"
require "minitest/autorun"

module TelemetryCapture
  def capture_events
    events = []
    sub = Odoshi::Telemetry.subscribe { |e| events << e }
    yield events
  ensure
    Odoshi::Telemetry.unsubscribe(sub)
  end

  def spawns(events, id) = events.count { |e| e[:event].last == :spawn && e[:metadata][:id] == id }
end
