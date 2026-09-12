# frozen_string_literal: true
# Usage: ruby tcp_server.rb PORT [DELAY]
# Sleeps DELAY seconds (simulating slow boot), then accepts TCP connections.
require "socket"
port, delay = ARGV[0].to_i, (ARGV[1] || "0").to_f
sleep delay
server = TCPServer.new("127.0.0.1", port)
loop do
  client = server.accept
  client.close
end
