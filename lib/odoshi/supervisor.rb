# frozen_string_literal: true
module Odoshi
  # DESIGN §3.1 / §3.3. One supervisor, an ordered set of children, one strategy.
  # Nested supervisors (subtrees) are ordinary children via Adapters::SupervisorAdapter:
  # a subtree escalating shows up here as a crashed child exit.
  class Supervisor
    attr_reader :children, :strategy, :intensity, :backoff

    def initialize(strategy: :one_for_one, intensity: RestartIntensity.new, backoff: Backoff.new,
                   socket_path: nil)
      raise ConfigError, "unknown strategy #{strategy}" unless Strategy::KINDS.include?(strategy)
      @strategy, @intensity, @backoff = strategy, intensity, backoff
      @children = [] # ordered ChildSpecs
      @live = {}     # id => { adapter:, handle:, attempts:, generation:, monitor: }
      @queue = Queue.new
      @stopping = false
      @stop_requested = false
      @heartbeats = {} # id => { at: monotonic ts of last heartbeat, state: reported state }
      return unless socket_path
      @socket = SocketServer.new(
        path: socket_path,
        # Heartbeats for ids that aren't children of THIS supervisor are
        # dropped at intake: ghost ids must not grow the table unboundedly
        # (issue #16/#27). Subtree-grandchild routing is the open flat-id
        # question — until it's decided, their beats are dropped, not hoarded.
        on_heartbeat: lambda { |msg|
          id = msg["id"].to_sym
          @heartbeats[id] = { at: mono_now, state: msg["state"] } if @children.any? { |c| c.id == id }
        },
        on_control: ->(msg) { @queue << { type: :control, cmd: msg["cmd"], id: msg["id"].to_s.to_sym } }
      )
    end

    # The per-boot token children must echo in every heartbeat (nil when the
    # socket is disabled). Exported to children as ODOSHI_TOKEN.
    def heartbeat_token = @socket&.token

    def add_child(spec)
      raise ConfigError, "duplicate child id #{spec.id}" if @children.any? { |c| c.id == spec.id }
      @children << spec
      self
    end

    # Blocks until the tree is shut down. Raises Escalation if intensity is exceeded.
    def run
      Telemetry.emit(:"supervisor.start", {}, { strategy: strategy, children: ids })
      @socket&.start # before children, so they inherit ODOSHI_SOCK/_TOKEN
      @children.each do |spec|
        break if @stop_requested
        start_child(spec)
      end
      loop do
        msg = @queue.pop
        case msg[:type]
        when :exit then handle_exit(msg[:id], msg[:generation], msg[:status])
        when :health_dead then handle_health_dead(msg[:id], msg[:generation])
        when :control then handle_control(msg)
        when :stop then break
        end
      end
    ensure
      stop_all
      @socket&.stop
      Telemetry.emit(:"supervisor.stop")
    end

    # Sets the flag first: the main loop may be stuck in a wait_healthy poll
    # or a backoff sleep for up to start_timeout/backoff seconds, and shutdown
    # must not wait for those (issue #28 — platforms SIGKILL after their grace
    # period, which resurrects the orphan problem).
    def stop
      @stop_requested = true
      @queue << { type: :stop }
    end

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
      @heartbeats.delete(spec.id) # a replaced child's heartbeats must not vouch for its successor
      adapter = Adapter.lookup(spec.adapter).new
      handle = adapter.spawn(spec)
      prev = @live[spec.id] || {}
      generation = (prev[:generation] || 0) + 1
      @live[spec.id] = { adapter: adapter, handle: handle, attempts: prev[:attempts] || 0, generation: generation }
      adapter.link(handle) do |status|
        @queue << { type: :exit, id: spec.id, generation: generation, status: status } unless @stopping
      end
      Telemetry.emit(:"child.spawn", {}, { id: spec.id, adapter: spec.adapter, pid: handle.respond_to?(:pid) ? handle.pid : nil })
      start_monitor(spec, generation) if wait_healthy(spec, adapter, handle) == :healthy
    end

    # PLAN 1.3: per-child polling thread. :degraded emits telemetry only,
    # unless degraded_restart_after consecutive reports accumulate; :dead from
    # a probe (not just SIGCHLD) goes through the exit queue like any crash.
    def start_monitor(spec, generation)
      return unless spec.health_interval
      entry = @live[spec.id]
      adapter, handle = entry[:adapter], entry[:handle]
      degraded = 0
      entry[:monitor] = Thread.new do
        loop do
          sleep spec.health_interval
          break if @stopping || @live.dig(spec.id, :generation) != generation
          case effective_health(spec, adapter, handle)
          when :healthy
            degraded = 0
            # One healthy interval resets the backoff ladder (#19): a child
            # that crashes rarely should not converge to permanent max
            # backoff. Crash-looping children never reach a monitor, so flap
            # damping is unaffected.
            entry[:attempts] = 0
          when :degraded
            degraded += 1
            Telemetry.emit(:"child.degraded", { consecutive: degraded }, { id: spec.id })
            if spec.degraded_restart_after && degraded >= spec.degraded_restart_after
              @queue << { type: :health_dead, id: spec.id, generation: generation }
              break
            end
          when :dead
            @queue << { type: :health_dead, id: spec.id, generation: generation }
            break
          end
        end
      end
    end

    def wait_healthy(spec, adapter, handle)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + spec.start_timeout
      loop do
        return :stopping if @stop_requested # shutdown must not wait out start_timeout (#28)
        case effective_health(spec, adapter, handle)
        when :healthy then Telemetry.emit(:"child.healthy", {}, { id: spec.id }); return :healthy
        when :dead    then return :dead # the exit message arrives via link
        end
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          # PLAN 1.2: start_timeout exceeded ⇒ drain. The resulting exit flows
          # through the normal link → handle_exit path, so it counts as a
          # crash and the strategy + intensity apply.
          stop_child(spec)
          return :timeout
        end
        sleep 0.05
      end
    end

    HEARTBEAT_STATES = { "starting" => :starting, "healthy" => :healthy,
                         "degraded" => :degraded, "dead" => :dead }.freeze

    # DESIGN §5/§9: health is active-first. A child that has heartbeated is
    # judged by heartbeat freshness and its own reported state — missing 3
    # intervals ⇒ :degraded, 6 ⇒ :dead. Children that never heartbeat fall
    # back to the adapter's passive probe.
    def effective_health(spec, adapter, handle)
      hb = @heartbeats[spec.id]
      # No heartbeat ⇒ passive probe. A nil health_interval (subtree specs)
      # also falls through: freshness aging needs an interval, and dividing
      # by nil crashed the whole tree when a heartbeat named such an id (#25).
      return adapter.health(handle) unless hb && spec.health_interval
      missed = (mono_now - hb[:at]) / spec.health_interval
      return :dead if missed >= 6
      return :degraded if missed >= 3
      HEARTBEAT_STATES.fetch(hb[:state], :healthy)
    end

    def mono_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # DESIGN §7/§9: {"cmd":"restart","id":...} over the socket — the transport
    # Rails.supervisor.restart! rides later. Unknown commands and ids are
    # ignored; the token was already checked at the socket layer.
    def handle_control(msg)
      return unless msg[:cmd] == "restart"
      return unless @children.any? { |c| c.id == msg[:id] }
      restart!(msg[:id])
    end

    # A monitor thread declared this child unhealthy enough to replace. Drain
    # it; the resulting real exit flows through link → handle_exit, so the
    # strategy and intensity apply exactly as for a crash (same path as the
    # 1.2 start_timeout drain). If the child already exited and was replaced,
    # the generation guard makes this a no-op.
    def handle_health_dead(id, generation)
      entry = @live[id]
      return if entry.nil? || entry[:generation] != generation
      stop_child(spec_for(id))
    end

    def handle_exit(id, generation, status)
      spec = spec_for(id)
      entry = @live[id]
      return if entry.nil? || entry[:generation] != generation # stale exit from a child we already replaced

      uptime = Process.clock_gettime(Process::CLOCK_MONOTONIC) - entry[:handle].started_at
      Telemetry.emit(:"child.exit", { exit_code: status&.exitstatus, uptime_ms: (uptime * 1000).round }, { id: id })
      unless spec.restart?(status)
        # The child is gone for good: keep no stale entry, or stop_all and the
        # monitor emit spurious drains for a corpse later (issue #20).
        entry[:monitor]&.kill
        @live.delete(id)
        return
      end

      if intensity.record!
        Telemetry.emit(:"supervisor.escalate", { restarts: intensity.count }, { within: intensity.within })
        raise Escalation, "restart intensity exceeded (#{intensity.count} in #{intensity.within}s)"
      end

      affected = Strategy.affected(strategy, ids, id)
      # OTP semantics (#14): declaration order encodes dependency, so first
      # terminate ALL affected children in reverse start order — a
      # replacement :b must never boot while an old :c that depended on the
      # dead :b is still running — then restart them in start order.
      affected.reverse_each do |aid|
        stop_child(spec_for(aid)) unless aid == id
      end
      affected.each do |aid|
        break if @stop_requested # shutdown preempts the restart fan-out (#28)
        entry = @live[aid]
        next unless entry # a temporary/clean-transient sibling is gone for good (#20)
        attempts = (entry[:attempts] += 1)
        delay = backoff.delay(attempts)
        Telemetry.emit(:"child.restart", { backoff_ms: (delay * 1000).round }, { id: aid, attempt: attempts, strategy: strategy })
        interruptible_sleep(delay)
        break if @stop_requested
        start_child(spec_for(aid))
      end
    end

    # Backoff must not delay shutdown (#28): sleep in slices, bail on stop.
    def interruptible_sleep(seconds)
      deadline = mono_now + seconds
      while mono_now < deadline
        return if @stop_requested
        sleep [0.1, deadline - mono_now].min
      end
    end

    def stop_child(spec)
      entry = @live[spec.id] or return
      entry[:monitor]&.kill
      entry[:monitor] = nil
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
