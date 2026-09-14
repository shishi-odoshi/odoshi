# frozen_string_literal: true
# Usage: ruby heartbeater.rb INTERVAL STOPFLAG [ID]
# Sends NDJSON heartbeats (DESIGN §5) over ODOSHI_SOCK every INTERVAL
# seconds until STOPFLAG exists — then goes silent but stays alive, which is
# how a wedged-but-running child looks to the supervisor.
require "socket"
require "json"

interval, stopflag, id = ARGV[0].to_f, ARGV[1], (ARGV[2] || "hb")
sock = nil
10.times do
  sock = UNIXSocket.new(ENV.fetch("ODOSHI_SOCK"))
  break
rescue SystemCallError
  sleep 0.1
end

loop do
  unless File.exist?(stopflag)
    sock.puts({ id: id, state: "healthy", ts: Time.now.to_i,
                token: ENV["ODOSHI_TOKEN"], meta: {} }.to_json)
  end
  sleep interval
end
