# frozen_string_literal: true
module OtpRails
  # DESIGN §3.1 / §3.3. One supervisor, an ordered set of children, one strategy.
  # Nested supervisors (subtrees) are a v0.2 deliverable.
  class Supervisor
    attr_reader :children, :strategy, :intensity, :backoff

    def initialize(strategy: :one_for_one, intensity: RestartIntensity.new, backoff: Backoff.new)
      raise ConfigError, "unknown strategy #{strategy}" unless Strategy::KINDS.include?(strategy)
      @strategy, @intensity, @backoff = strategy, intensity, backoff
      @children = [] # ordered ChildSpecs
      @live = {}     # id => { adapter:, handle:, attempts:, generation: }
      @queue = Queue.new
      @stopping = false
    end

    def add_child(spec)
      raise ConfigError, "duplicate child id #{spec.id}" if @children.any? { |c| c.id == spec.id }
      @children << spec
      self
    end

    # Blocks until the tree is shut down. Raises Escalation if intensity is exceeded.
    def run
      Telemetry.emit(:"supervisor.start", {}, { strategy: strategy, children: ids })
      @children.each { |spec| start_child(spec) }
      loop do
        msg = @queue.pop
        case msg[:type]
        when :exit then handle_exit(msg[:id], msg[:generation], msg[:status])
        when :stop then break
        end
      end
    ensure
      stop_all
      Telemetry.emit(:"supervisor.stop")
    end

    def stop = @queue << { type: :stop }

    # Public remediation API (DESIGN §7). Over IPC in the real thing; direct call here.
    def restart!(id)
      spec = spec_for(id)
      stop_child(spec)
      start_child(spec)
    end

    def ids = @children.map(&:id)

    # Debug/test hook. Not public API.
    def live_pid(id) = @live.dig(id, :handle)&.pid

    private

    def spec_for(id) = @children.find { |c| c.id == id } || raise(ArgumentError, "no child #{id}")

    def start_child(spec)
      adapter = Adapter.lookup(spec.adapter).new
      handle = adapter.spawn(spec)
      prev = @live[spec.id] || {}
      generation = (prev[:generation] || 0) + 1
      @live[spec.id] = { adapter: adapter, handle: handle, attempts: prev[:attempts] || 0, generation: generation }
      adapter.link(handle) do |status|
        @queue << { type: :exit, id: spec.id, generation: generation, status: status } unless @stopping
      end
      Telemetry.emit(:"child.spawn", {}, { id: spec.id, adapter: spec.adapter, pid: handle.respond_to?(:pid) ? handle.pid : nil })
      wait_healthy(spec, adapter, handle)
    end

    def wait_healthy(spec, adapter, handle)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + spec.start_timeout
      loop do
        case adapter.health(handle)
        when :healthy then Telemetry.emit(:"child.healthy", {}, { id: spec.id }); return
        when :dead    then return # the exit message arrives via link
        end
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          # PLAN 1.2: start_timeout exceeded ⇒ drain. The resulting exit flows
          # through the normal link → handle_exit path, so it counts as a
          # crash and the strategy + intensity apply.
          stop_child(spec)
          return
        end
        sleep 0.05
      end
    end

    def handle_exit(id, generation, status)
      spec = spec_for(id)
      entry = @live[id]
      return if entry.nil? || entry[:generation] != generation # stale exit from a child we already replaced

      uptime = Process.clock_gettime(Process::CLOCK_MONOTONIC) - entry[:handle].started_at
      Telemetry.emit(:"child.exit", { exit_code: status&.exitstatus, uptime_ms: (uptime * 1000).round }, { id: id })
      return unless spec.restart?(status)

      if intensity.record!
        Telemetry.emit(:"supervisor.escalate", { restarts: intensity.count }, { within: intensity.within })
        raise Escalation, "restart intensity exceeded (#{intensity.count} in #{intensity.within}s)"
      end

      Strategy.affected(strategy, ids, id).each do |aid|
        aspec = spec_for(aid)
        stop_child(aspec) unless aid == id
        attempts = (@live[aid][:attempts] += 1)
        delay = backoff.delay(attempts)
        Telemetry.emit(:"child.restart", { backoff_ms: (delay * 1000).round }, { id: aid, attempt: attempts, strategy: strategy })
        sleep delay
        start_child(aspec)
      end
    end

    def stop_child(spec)
      entry = @live[spec.id] or return
      Telemetry.emit(:"child.drain", {}, { id: spec.id })
      return if entry[:adapter].drain(entry[:handle], timeout: spec.shutdown)
      Telemetry.emit(:"child.kill", {}, { id: spec.id })
      entry[:adapter].kill(entry[:handle])
    end

    def stop_all
      @stopping = true
      @children.reverse_each { |spec| stop_child(spec) }
    end
  end
end
