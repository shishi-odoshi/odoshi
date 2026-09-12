# frozen_string_literal: true
require "test_helper"

class StrategyTest < Minitest::Test
  IDS = %i[web cable jobs cron].freeze

  def test_one_for_one
    assert_equal %i[cable], OtpRails::Strategy.affected(:one_for_one, IDS, :cable)
  end

  def test_rest_for_one_restarts_failed_and_later_children
    assert_equal %i[cable jobs cron], OtpRails::Strategy.affected(:rest_for_one, IDS, :cable)
  end

  def test_one_for_all
    assert_equal IDS, OtpRails::Strategy.affected(:one_for_all, IDS, :cron)
  end
end

class RestartIntensityTest < Minitest::Test
  def test_escalates_when_more_than_max_within_window
    t = 0.0
    ri = OtpRails::RestartIntensity.new(max_restarts: 2, within: 10, clock: -> { t })
    refute ri.record!; t += 1
    refute ri.record!; t += 1
    assert ri.record!, "third restart within 10s must escalate"
  end

  def test_old_restarts_fall_out_of_window
    t = 0.0
    ri = OtpRails::RestartIntensity.new(max_restarts: 2, within: 10, clock: -> { t })
    ri.record!; ri.record!
    t += 11
    refute ri.record!
  end
end

class ChildSpecTest < Minitest::Test
  Status = Struct.new(:success?)
  def spec(kind) = OtpRails::ChildSpec.new(id: :x, adapter: :command, restart: kind)

  def test_permanent_always_restarts
    assert spec(:permanent).restart?(Status.new(true))
  end

  def test_transient_only_on_failure
    refute spec(:transient).restart?(Status.new(true))
    assert spec(:transient).restart?(Status.new(false))
  end

  def test_temporary_never_restarts
    refute spec(:temporary).restart?(Status.new(false))
  end
end

class DSLTest < Minitest::Test
  def test_example_config_builds
    sup = OtpRails::DSL.load_file(File.expand_path("../examples/supervisor.rb", __dir__))
    assert_equal :rest_for_one, sup.strategy
    assert_equal %i[web jobs], sup.ids
  end
end
