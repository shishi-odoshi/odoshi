# frozen_string_literal: true
module OtpRails
  # PLAN 1.1 orphan prevention: if the supervisor is SIGKILLed, children should
  # still receive SIGTERM. Linux delivers this via prctl(PR_SET_PDEATHSIG),
  # armed in the forked child between fork and exec. macOS/BSD have no
  # equivalent: children there are re-parented to launchd/init and keep running
  # until the platform supervisor reaps them (documented limitation, README).
  module OrphanGuard
    PR_SET_PDEATHSIG = 1

    def self.available?
      return @available if defined?(@available)
      @available = RUBY_PLATFORM.include?("linux") && fiddle?
    end

    def self.fiddle?
      require "fiddle"
      true
    rescue LoadError
      false
    end

    # Runs in the forked child, pre-exec. parent_pid is the supervisor's pid at
    # fork time: pdeathsig is not delivered if the parent died before prctl ran,
    # so re-check the parent afterwards and exit rather than run orphaned.
    def self.arm!(parent_pid, signal: "TERM")
      return false unless available?
      libc = Fiddle.dlopen(nil)
      prctl = Fiddle::Function.new(libc["prctl"], [Fiddle::TYPE_INT] * 5, Fiddle::TYPE_INT)
      armed = prctl.call(PR_SET_PDEATHSIG, Signal.list.fetch(signal), 0, 0, 0).zero?
      Process.exit!(0) if Process.ppid != parent_pid
      armed
    end
  end
end
