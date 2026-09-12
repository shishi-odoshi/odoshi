# frozen_string_literal: true
# Usage: ruby term_logger.rb ID LOGFILE [LINGER]
# Appends "UP ID" at boot. On SIGTERM appends "TERM ID", lingers LINGER seconds
# (simulating in-flight work), appends "EXIT ID", exits 0.
id, log, linger = ARGV[0], ARGV[1], (ARGV[2] || "0.2").to_f

stamp = lambda do |tag|
  File.open(log, "a") do |f|
    f.flock(File::LOCK_EX)
    f.puts("#{tag} #{id}")
  end
end

term = false
Signal.trap("TERM") { term = true }
stamp.call("UP")
sleep 0.02 until term
stamp.call("TERM")
sleep linger
stamp.call("EXIT")
exit 0
