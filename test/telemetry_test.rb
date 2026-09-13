# frozen_string_literal: true
require "test_helper"
require "stringio"

# QA (resilience#1 root cause): one raising subscriber must never starve the
# others or push its exception back into the emitting path — emit is called
# from the supervisor loop and monitor threads.
class TelemetryTest < Minitest::Test
  def test_a_raising_subscriber_does_not_break_the_bus
    received = []
    bad = OtpRails::Telemetry.subscribe { |_e| raise "buggy subscriber" }
    good = OtpRails::Telemetry.subscribe { |e| received << e }
    err = capture_warn do
      event = OtpRails::Telemetry.emit(:"child.healthy", {}, { id: :x })
      refute_nil event, "emit must return the event, not raise"
    end
    assert_equal 1, received.size, "subscribers after the raising one must still receive the event"
    assert_match(/buggy subscriber/, err, "the failure is surfaced, not swallowed silently")
  ensure
    OtpRails::Telemetry.unsubscribe(bad)
    OtpRails::Telemetry.unsubscribe(good)
  end

  def test_unknown_event_names_still_raise
    assert_raises(ArgumentError) { OtpRails::Telemetry.emit(:"child.invented") }
  end

  private

  def capture_warn
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end
end
