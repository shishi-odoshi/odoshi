# frozen_string_literal: true
module Odoshi
  # Evaluates config/supervisor.rb WITHOUT Rails loaded (DESIGN §9).
  #
  #   strategy :rest_for_one
  #   max_restarts 5, within: 60
  #   backoff :exponential, base: 1, cap: 30
  #   child :web,  adapter: :command, cmd: "bundle exec puma -C config/puma.rb"
  #   child :jobs, adapter: :command, cmd: "bin/jobs"
  #   supervisor :background do          # DESIGN §3.1: nested subtree with its
  #     strategy :one_for_all            # own strategy/intensity/backoff
  #     child :cron, adapter: :command, cmd: "bin/rails cron"
  #   end
  class DSL
    def self.load_file(path)
      dsl = new
      dsl.instance_eval(File.read(path), path, 1)
      dsl.build
    end

    def initialize(root: true)
      @root = root
      @strategy = :one_for_one
      @intensity = { max_restarts: 5, within: 60 }
      @backoff = { kind: :exponential, base: 1, cap: 30 }
      @children = []
      # DESIGN §5/§9 default; socket nil disables. Only the ROOT supervisor
      # listens — subtrees never bind their own socket.
      @socket_path = root ? "tmp/odoshi.sock" : nil
    end

    def strategy(kind) = @strategy = kind
    def max_restarts(n, within:) = @intensity = { max_restarts: n, within: within }
    def backoff(kind, **opts) = @backoff = { kind: kind, **opts }

    def socket(path)
      raise ConfigError, "socket can only be set on the root supervisor" unless @root
      @socket_path = path
    end

    # DESIGN §3.1: `supervisor :background do ... end` creates a subtree — a
    # :supervisor child whose block supports the full DSL (strategy /
    # max_restarts / backoff / child, and further nesting). The block is kept
    # as a builder so every (re)start constructs a FRESH child Supervisor:
    # RestartIntensity is stateful, and a restarted subtree must start with a
    # clean intensity window.
    def supervisor(id, restart: :permanent, shutdown: 30, start_timeout: 30, &block)
      raise ConfigError, "supervisor #{id.inspect} requires a block" unless block
      builder = lambda do
        sub = DSL.new(root: false)
        sub.instance_eval(&block)
        sub.build
      end
      builder.call # fail fast at config load, not at spawn time
      # health_interval nil: subtree liveness arrives via link (thread death),
      # and its internal health is the subtree supervisor's own business — no
      # probe monitor needed in the parent.
      @children << ChildSpec.new(id: id, adapter: :supervisor, restart: restart,
                                 shutdown: shutdown, start_timeout: start_timeout,
                                 health_interval: nil, opts: { builder: builder })
    end

    def child(id, adapter:, restart: :permanent, shutdown: 30, start_timeout: 30,
              health_interval: 5, degraded_restart_after: nil, **opts)
      @children << ChildSpec.new(id: id, adapter: adapter, restart: restart, shutdown: shutdown,
                                 start_timeout: start_timeout, health_interval: health_interval,
                                 degraded_restart_after: degraded_restart_after, opts: opts)
    end

    def build
      sup = Supervisor.new(strategy: @strategy,
                           intensity: RestartIntensity.new(**@intensity),
                           backoff: Backoff.new(**@backoff),
                           socket_path: @socket_path)
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
