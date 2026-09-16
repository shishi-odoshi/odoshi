# frozen_string_literal: true
require "test_helper"

class StrategyTest < Minitest::Test
  # Slots since 0.4.0 (P1): singleton slots ≡ the pre-replica behavior.
  SLOTS = [%i[web], %i[cable], %i[jobs], %i[cron]].freeze
  # web, then a 3-replica jobs group, then cron.
  GROUPED = [%i[web], %i[jobs.1 jobs.2 jobs.3], %i[cron]].freeze

  def test_one_for_one
    assert_equal %i[cable], Odoshi::Strategy.affected(:one_for_one, SLOTS, :cable)
  end

  def test_rest_for_one_restarts_failed_and_later_children
    assert_equal %i[cable jobs cron], Odoshi::Strategy.affected(:rest_for_one, SLOTS, :cable)
  end

  def test_one_for_all
    assert_equal %i[web cable jobs cron], Odoshi::Strategy.affected(:one_for_all, SLOTS, :cron)
  end

  def test_replica_crash_is_absorbed_by_the_group_under_rest_for_one
    assert_equal %i[jobs.2], Odoshi::Strategy.affected(:rest_for_one, GROUPED, :"jobs.2"),
                 "a lost replica never takes the slot's service down: peers keep serving, dependents keep running"
  end

  def test_earlier_slot_crash_restarts_the_whole_group
    assert_equal %i[web jobs.1 jobs.2 jobs.3 cron], Odoshi::Strategy.affected(:rest_for_one, GROUPED, :web)
  end

  def test_replica_crash_under_one_for_one_is_just_that_replica
    assert_equal %i[jobs.3], Odoshi::Strategy.affected(:one_for_one, GROUPED, :"jobs.3")
  end
end

class RestartIntensityTest < Minitest::Test
  def test_escalates_when_more_than_max_within_window
    t = 0.0
    ri = Odoshi::RestartIntensity.new(max_restarts: 2, within: 10, clock: -> { t })
    refute ri.record!; t += 1
    refute ri.record!; t += 1
    assert ri.record!, "third restart within 10s must escalate"
  end

  def test_old_restarts_fall_out_of_window
    t = 0.0
    ri = Odoshi::RestartIntensity.new(max_restarts: 2, within: 10, clock: -> { t })
    ri.record!; ri.record!
    t += 11
    refute ri.record!
  end
end

class ChildSpecTest < Minitest::Test
  Status = Struct.new(:success?)
  def spec(kind) = Odoshi::ChildSpec.new(id: :x, adapter: :command, restart: kind)

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
    sup = Odoshi::DSL.load_file(File.expand_path("../examples/supervisor.rb", __dir__))
    assert_equal :rest_for_one, sup.strategy
    assert_equal %i[web jobs], sup.ids
  end
end
