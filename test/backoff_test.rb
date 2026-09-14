# frozen_string_literal: true
require "test_helper"

# odoshi-template#1: the first restart of a crashed child is immediate (OTP
# convention); the exponential ladder applies from the second consecutive
# attempt. Crash-loop protection is intensity's job, not the first delay's.
class BackoffTest < Minitest::Test
  def test_exponential_first_restart_is_immediate
    b = Odoshi::Backoff.new(kind: :exponential, base: 1, cap: 30)
    assert_equal [0.0, 1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0],
                 (1..8).map { |a| b.delay(a) }
  end

  def test_constant_stays_constant
    b = Odoshi::Backoff.new(kind: :constant, base: 0.5)
    assert_equal [0.5, 0.5, 0.5], (1..3).map { |a| b.delay(a) }
  end

  def test_none_is_zero
    assert_equal 0.0, Odoshi::Backoff.new(kind: :none).delay(1)
  end
end
