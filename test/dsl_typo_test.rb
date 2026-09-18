# frozen_string_literal: true
require "test_helper"

# 0.4.1 — a typo'd lifecycle option used to vanish into the adapter opts
# hash: `cont: 4` silently produced ONE child instead of four (found by
# odoshi-bench). Adapter opts stay open by design, so only near-misses of
# lifecycle option names are rejected — with a suggestion.
class DslTypoTest < Minitest::Test
  def test_typoed_lifecycle_options_raise_with_a_suggestion
    {
      { cont: 4 } => :count,
      { conut: 2 } => :count,
      { shutdwn: 60 } => :shutdown,
      { restrt: :transient } => :restart,
      { health_intervals: 5 } => :health_interval,
      { start_timout: 10 } => :start_timeout
    }.each do |bad, expected|
      err = assert_raises(Odoshi::ConfigError, "#{bad.keys.first} should be caught") do
        Odoshi.supervise { socket nil; child :jobs, adapter: :command, cmd: "sleep 1", **bad }
      end
      assert_match(/did you mean #{expected.inspect}/, err.message)
    end
  end

  def test_adapter_options_still_pass_through_untouched
    sup = Odoshi.supervise do
      socket nil
      child :web, adapter: :puma, cmd: "sleep 1", port: 3000, config: "config/puma.rb",
                  env: { "X" => "1" }, probe: { tcp: 3000 }, spawn_opts: {}
    end
    opts = sup.children.first.opts
    assert_equal 3000, opts[:port]
    assert_equal({ "X" => "1" }, opts[:env])
    assert_equal({ tcp: 3000 }, opts[:probe])
  end

  def test_correctly_spelled_options_are_not_flagged
    sup = Odoshi.supervise do
      socket nil
      child :jobs, adapter: :command, cmd: "sleep 1", count: 2, shutdown: 60,
                   restart: :transient, start_timeout: 10, health_interval: 1,
                   degraded_restart_after: 3
    end
    assert_equal %i[jobs.1 jobs.2], sup.ids
  end
end
