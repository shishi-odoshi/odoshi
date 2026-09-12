# frozen_string_literal: true
# Usage: ruby flaky_http_server.rb PORT FLAGFILE
# Answers 200 "ok" until FLAGFILE exists, then 503 — the child stays alive but
# stops being healthy, which is exactly what :degraded means (DESIGN §5).
require "socket"
port, flag = ARGV[0].to_i, ARGV[1]
server = TCPServer.new("127.0.0.1", port)
loop do
  client = server.accept
  client.gets # request line
  while (line = client.gets) && line != "\r\n"; end # drain headers
  if File.exist?(flag)
    client.write "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 4\r\nConnection: close\r\n\r\nsick"
  else
    client.write "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
  end
  client.close
rescue IOError, SystemCallError
  next
end
