# frozen_string_literal: true
module OtpRails
  module Adapters
    # DESIGN §4.1 :command — arbitrary command. Health = PID alive (+ optional probe, TODO).
    class Command < Adapter
      Handle = Struct.new(:pid, :spec, :started_at, :exit_status, :waiter)

      def spawn(spec)
        cmd = spec.opts.fetch(:cmd) { raise ConfigError, "#{spec.id}: :command adapter requires cmd:" }
        env = spec.opts.fetch(:env, {}).transform_keys(&:to_s)
        spawn_opts = spec.opts.fetch(:spawn_opts, {})
        pid =
          if OrphanGuard.available?
            parent = Process.pid
            Process.fork do
              Process.setsid # own session ⇒ own pgroup, same as pgroup: true below
              OrphanGuard.arm!(parent)
              begin
                Process.exec(env, cmd, **spawn_opts)
              rescue SystemCallError
                Process.exit!(127)
              end
            end
          else
            Process.spawn(env, cmd, pgroup: true, **spawn_opts)
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
        Probe.answering?(handle.spec) ? :healthy : :starting
      rescue Errno::ESRCH
        :dead
      end

      def drain(handle, timeout:)
        Process.kill("TERM", handle.pid)
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
    end
  end
  Adapter.register(:command, Adapters::Command)
end
