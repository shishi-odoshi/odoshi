# frozen_string_literal: true
module Odoshi
  module Adapters
    # DESIGN §3.1 nested supervisors. A subtree is just another child of the
    # parent: this pseudo-adapter runs a child Supervisor on a Thread and maps
    # the four adapter operations onto it. Escalation inside the subtree
    # terminates the thread, which surfaces to the parent as a crashed exit —
    # the parent then applies ITS strategy/intensity to the subtree child
    # (restart the whole subtree, etc.), exactly per OTP semantics.
    #
    # opts:
    #   builder: a Proc returning a FRESH Odoshi::Supervisor each call.
    #            A restarted subtree must not inherit the old subtree's
    #            RestartIntensity window (it is stateful), so spawn re-invokes
    #            the builder on every (re)start instead of reusing an instance.
    class SupervisorAdapter < Adapter
      # Duck-types the two things the tree asks of an exit status:
      # #exitstatus (telemetry) and #success? (ChildSpec#restart? semantics).
      Status = Struct.new(:exitstatus) do
        def success? = exitstatus == 0
      end

      Handle = Struct.new(:sub, :thread, :started_at, :exit_status, :waiter, :killed)

      def spawn(spec)
        builder = spec.opts.fetch(:builder) do
          raise ConfigError, "#{spec.id}: :supervisor adapter requires builder: (a proc returning a fresh Supervisor)"
        end
        sub = builder.call
        raise ConfigError, "#{spec.id}: builder must return an Odoshi::Supervisor" unless sub.is_a?(Supervisor)
        thread = Thread.new { sub.run }
        # Escalation out of a subtree is an expected, handled exit path — the
        # waiter converts it into a crashed status. Don't let Ruby dump it.
        thread.report_on_exception = false
        Handle.new(sub, thread, Process.clock_gettime(Process::CLOCK_MONOTONIC), nil, nil, false)
      end

      def link(handle, &on_exit)
        handle.waiter = Thread.new do
          status =
            begin
              handle.thread.join # re-raises whatever terminated the subtree
              Status.new(handle.killed ? nil : 0)
            rescue Escalation
              Status.new(70) # crashed: intensity exceeded inside the subtree
            rescue StandardError
              Status.new(1)  # crashed: unexpected error in the subtree loop
            end
          handle.exit_status = status
          on_exit.call(status)
        end
      end

      # The subtree's internal health is its own supervisor's business; from
      # the parent's seat the subtree is healthy while its loop is running.
      # Death also arrives via link, so parents normally give subtree specs
      # health_interval: nil (the DSL does) and skip the probe monitor.
      def health(handle)
        handle.thread.alive? ? :healthy : :dead
      end

      # Clean stop: the subtree's run loop breaks and its `ensure stop_all`
      # drains the subtree's own children (reverse order) before the thread
      # exits — so by the time this returns true, no subtree PIDs remain.
      def drain(handle, timeout:)
        handle.sub.stop
        joined =
          begin
            handle.thread.join(timeout)
          rescue StandardError
            handle.thread # join re-raised => the thread has terminated
          end
        !joined.nil?
      end

      # Last resort. Thread#kill still runs the subtree's `ensure stop_all`;
      # if even that wedges, best-effort drain the subtree's children directly
      # so no grandchild PIDs are orphaned.
      def kill(handle)
        handle.killed = true
        handle.thread.kill
        joined =
          begin
            handle.thread.join(2)
          rescue StandardError
            handle.thread
          end
        handle.sub.send(:stop_all) if joined.nil? # loop wedged: drain grandchildren ourselves
      rescue StandardError
        nil
      end
    end
  end
  Adapter.register(:supervisor, Adapters::SupervisorAdapter)
end
