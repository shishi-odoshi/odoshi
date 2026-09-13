# frozen_string_literal: true
module OtpRails
  module Adapters
    # DESIGN §4.1 :command — arbitrary command. Health = PID alive (+ optional probe, TODO).
    class Command < Adapter
      Handle = Struct.new(:pid, :spec, :started_at, :exit_status, :waiter, :healthy_once)

      def spawn(spec)
        cmd = spec.opts.fetch(:cmd) { raise ConfigError, "#{spec.id}: :command adapter requires cmd:" }
        env = spec.opts.fetch(:env, {}).transform_keys(&:to_s)
        spawn_opts = spec.opts.fetch(:spawn_opts, {})
        # One spawn path on every platform (#15): fork → setsid → exec, with
        # exec failure becoming exit 127 through the normal link → crash →
        # strategy machinery. Process.spawn raised Errno::ENOENT into the
        # supervisor loop for a bad cmd on macOS (whole tree crashed, exit 1)
        # while the Linux fork path restart-looped to escalation (exit 70).
        parent = Process.pid
        pid = Process.fork do
          Process.setsid # own session ⇒ own pgroup (drain/kill signal the group)
          OrphanGuard.arm!(parent)
          begin
            Process.exec(env, cmd, **spawn_opts)
          rescue StandardError
            Process.exit!(127)
          end
        end
        Handle.new(pid, spec, Process.clock_gettime(Process::CLOCK_MONOTONIC), nil, nil)
      end

      def link(handle, &on_exit)
        handle.waiter = Thread.new do
          _, status = Process.wait2(handle.pid)
          handle.exit_status = status
          on_exit.call(status)
        rescue Errno::ECHILD
          on_exit.call(nil)
        end
      end

      def health(handle)
        return :dead if handle.exit_status
        Process.kill(0, handle.pid)
        if Probe.answering?(handle.spec)
          handle.healthy_once = true
          :healthy
        elsif handle.healthy_once
          :degraded # was healthy, probe stopped answering, PID still alive (§5)
        else
          :starting
        end
      rescue Errno::ESRCH
        :dead
      end

      def drain(handle, timeout:)
        # Signal the whole process group, not just handle.pid: children are
        # group leaders (setsid / pgroup: true), and a shell-wrapped cmd
        # ("a && b") is an sh wrapper whose real workload is a grandchild in
        # that group — TERM to the wrapper alone orphans the workload while
        # reporting a clean drain (issue #24).
        group_signal("TERM", handle.pid)
        handle.waiter&.join(timeout)
        !handle.exit_status.nil?
      rescue Errno::ESRCH
        true
      end

      def kill(handle)
        Process.kill("KILL", -handle.pid) # whole process group
        handle.waiter&.join(2)
      rescue Errno::ESRCH
        nil
      end

      private

      # TERM the group; fall back to the pid alone if the group is already
      # gone by the time we signal (pure pid death races to the outer ESRCH).
      def group_signal(sig, pid)
        Process.kill(sig, -pid)
      rescue Errno::ESRCH
        Process.kill(sig, pid)
      end
    end
  end
  Adapter.register(:command, Adapters::Command)
end
