# frozen_string_literal: true
# Usage: ruby pid_writer.rb PIDFILE TERMFILE — writes its pid, then sleeps.
# On SIGTERM it writes TERMFILE and exits: proof of delivery that survives the
# child becoming an unreaped zombie (kill(0, pid) still succeeds on zombies,
# so tests must not use process aliveness to detect the signal).
Signal.trap("TERM") do
  File.write(ARGV[1], "TERM") if ARGV[1]
  exit! 0
end
File.write(ARGV[0], Process.pid.to_s)
sleep 60
