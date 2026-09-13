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
    MAX_LINE = 64 * 1024 # §5: longer lines are malformed and dropped
    MAX_CONNS = 64       # excess connections are refused (closed immediately)

    attr_reader :path, :token

    def initialize(path:, on_heartbeat:, on_control:)
      @path, @on_heartbeat, @on_control = path, on_heartbeat, on_control
      @token = SecureRandom.hex(16)
      @conns = []
    end

    # Binds, chmods, and exports OTP_RAILS_SOCK / OTP_RAILS_TOKEN so children
    # spawned afterwards inherit them (DESIGN §9). Call before starting children.
    def start
      begin
        FileUtils.mkdir_p(File.dirname(@path))
        File.unlink(@path) if File.exist?(@path) # stale socket from a dead boot
        @server = UNIXServer.new(@path)
      rescue ArgumentError, SystemCallError => e
        # e.g. > ~104-byte path on macOS, unwritable dir: config problem, not a crash
        raise ConfigError, "heartbeat socket #{@path.inspect}: #{e.message}"
      end
      @server.listen(128) # default backlog is 5 on macOS; bursts got ECONNREFUSED
      File.chmod(0o600, @path)
      ENV["OTP_RAILS_SOCK"] = @path
      ENV["OTP_RAILS_TOKEN"] = @token
      @acceptor = Thread.new do
        loop do
          conn = @server.accept
          @conns.reject! { |c| !c[:thread].alive? }
          if @conns.size >= MAX_CONNS
            close_quietly(conn)
            next
          end
          @conns << { conn: conn, thread: Thread.new { serve(conn) } }
        rescue IOError, SystemCallError
          break # server closed during shutdown
        end
      end
    end

    def stop
      @server&.close
      @acceptor&.kill
      @conns.each do |c| # connection threads must not outlive the server
        c[:thread].kill
        close_quietly(c[:conn])
      end
      @conns.clear
      File.unlink(@path) if File.exist?(@path)
    rescue SystemCallError
      nil
    end

    private

    def serve(conn)
      loop do
        line = conn.gets("\n", MAX_LINE)
        break if line.nil?
        unless line.end_with?("\n")
          # over-long line: memory stays capped at MAX_LINE — discard the rest
          # of the line, then resume at the next newline
          line = conn.gets("\n", MAX_LINE) while !line.nil? && !line.end_with?("\n")
          break if line.nil?
          next
        end
        handle_line(line)
      end
    rescue IOError, SystemCallError
      nil
    ensure
      close_quietly(conn)
    end

    # §5: token, cmd, id, and state are JSON strings; anything else in those
    # fields is malformed and silently dropped — same as a bad token. A bad
    # line must never take the connection (or the supervisor) down.
    def handle_line(line)
      msg = begin
        JSON.parse(line)
      rescue StandardError
        return
      end
      return unless msg.is_a?(Hash) && msg["token"] == @token
      if msg.key?("cmd")
        @on_control.call(msg) if msg["cmd"].is_a?(String)
      elsif msg["id"].is_a?(String) && msg["state"].is_a?(String)
        @on_heartbeat.call(msg)
      end
    end

    def close_quietly(conn)
      conn.close
    rescue IOError, SystemCallError
      nil
    end
  end
end
