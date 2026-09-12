# frozen_string_literal: true
# Usage: ruby bad_heartbeater.rb — sends one heartbeat with a WRONG token,
# then stays alive silently. If the supervisor wrongly accepted it, the child
# would become "active" and the ensuing silence would get it restarted; if the
# heartbeat is dropped (correct), the child stays passive and healthy.
require "socket"
require "json"

sock = nil
10.times do
  sock = UNIXSocket.new(ENV.fetch("OTP_RAILS_SOCK"))
  break
rescue SystemCallError
  sleep 0.1
end
sock.puts({ id: "hb", state: "healthy", ts: Time.now.to_i, token: "wrong-token", meta: {} }.to_json)
sleep 60
