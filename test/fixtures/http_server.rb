# frozen_string_literal: true
# Usage: ruby http_server.rb PORT [DELAY]
# Sleeps DELAY seconds, then answers every request with 200 "ok".
require "socket"
port, delay = ARGV[0].to_i, (ARGV[1] || "0").to_f
sleep delay
server = TCPServer.new("127.0.0.1", port)
loop do
  client = server.accept
  client.gets # request line
  while (line = client.gets) && line != "\r\n"; end # drain headers
  client.write "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
  client.close
rescue IOError, SystemCallError
  next
end
