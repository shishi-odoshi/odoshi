# frozen_string_literal: true
require "socket"
require "json"
require "securerandom"
require "fileutils"

module OtpRails
  # DESIGN §5 active heartbeats + §9 control transport, PLAN 1.4.
  # Newline-delimited JSON over a Unix socket, mode 0600, per-boot token —
  # no MessagePack, no length prefixes, no versions (hard rule 4). This wire
  # format is the contract the Elixir `beam` repo consumes.
  #
  # Heartbeat:  {"id":"jobs","state":"healthy","ts":1757700000,"token":"…","meta":{}}
  # Control:    {"cmd":"restart","id":"jobs","token":"…"}
  # Any line with a missing or wrong token is dropped without a reply.
  class SocketServer
    attr_reader :path, :token

    def initialize(path:, on_heartbeat:, on_control:)
      @path, @on_heartbeat, @on_control = path, on_heartbeat, on_control
      @token = SecureRandom.hex(16)
    end

    # Binds, chmods, and exports OTP_RAILS_SOCK / OTP_RAILS_TOKEN so children
    # spawned afterwards inherit them (DESIGN §9). Call before starting children.
    def start
      FileUtils.mkdir_p(File.dirname(@path))
      File.unlink(@path) if File.exist?(@path) # stale socket from a dead boot
      @server = UNIXServer.new(@path)
      File.chmod(0o600, @path)
      ENV["OTP_RAILS_SOCK"] = @path
      ENV["OTP_RAILS_TOKEN"] = @token
      @acceptor = Thread.new do
        loop do
          conn = @server.accept
          Thread.new { serve(conn) }
        rescue IOError, SystemCallError
          break # server closed during shutdown
        end
      end
    end

    def stop
      @server&.close
      @acceptor&.kill
      File.unlink(@path) if File.exist?(@path)
    rescue SystemCallError
      nil
    end

    private

    def serve(conn)
      conn.each_line do |line|
        msg = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        next unless msg["token"] == @token # bad token ⇒ dropped
        if msg["cmd"]
          @on_control.call(msg)
        elsif msg["id"] && msg["state"]
          @on_heartbeat.call(msg)
        end
      end
    rescue IOError, SystemCallError
      nil
    ensure
      begin
        conn.close
      rescue IOError
        nil
      end
    end
  end
end
