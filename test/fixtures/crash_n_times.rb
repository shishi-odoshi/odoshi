# frozen_string_literal: true
# Usage: ruby crash_n_times.rb COUNTER_FILE N
# Increments a run counter in COUNTER_FILE. Runs 1..N exit 1 immediately
# (crash); run N+1 onward sleeps forever (finally healthy). Lets tests drive a
# subtree over its restart intensity a bounded number of times, then settle.
path, n = ARGV[0], ARGV[1].to_i
count = (File.exist?(path) ? File.read(path).to_i : 0) + 1
File.write(path, count.to_s)
exit 1 if count <= n
Signal.trap("TERM") { exit! 0 }
sleep 300
