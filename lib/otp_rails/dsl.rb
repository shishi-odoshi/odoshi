# frozen_string_literal: true
module OtpRails
  # Evaluates config/supervisor.rb WITHOUT Rails loaded (DESIGN §9).
  #
  #   strategy :rest_for_one
  #   max_restarts 5, within: 60
  #   backoff :exponential, base: 1, cap: 30
  #   child :web,  adapter: :command, cmd: "bundle exec puma -C config/puma.rb"
  #   child :jobs, adapter: :command, cmd: "bin/jobs"
  class DSL
    def self.load_file(path)
      dsl = new
      dsl.instance_eval(File.read(path), path, 1)
      dsl.build
    end

    def initialize
      @strategy = :one_for_one
      @intensity = { max_restarts: 5, within: 60 }
      @backoff = { kind: :exponential, base: 1, cap: 30 }
      @children = []
    end

    def strategy(kind) = @strategy = kind
    def max_restarts(n, within:) = @intensity = { max_restarts: n, within: within }
    def backoff(kind, **opts) = @backoff = { kind: kind, **opts }

    def child(id, adapter:, restart: :permanent, shutdown: 30, start_timeout: 30,
              health_interval: 5, degraded_restart_after: nil, **opts)
      @children << ChildSpec.new(id: id, adapter: adapter, restart: restart, shutdown: shutdown,
                                 start_timeout: start_timeout, health_interval: health_interval,
                                 degraded_restart_after: degraded_restart_after, opts: opts)
    end

    def build
      sup = Supervisor.new(strategy: @strategy,
                           intensity: RestartIntensity.new(**@intensity),
                           backoff: Backoff.new(**@backoff))
      @children.each { |c| sup.add_child(c) }
      sup
    end
  end

  def self.supervise(&block)
    dsl = DSL.new
    dsl.instance_eval(&block)
    dsl.build
  end
end
