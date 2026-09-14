# frozen_string_literal: true
require "socket"
require "net/http"
require "uri"

module Odoshi
  # Passive probes (DESIGN §4.1/§5): a child declared with probe: opts is
  # :starting until the probe answers, then :healthy. Probes are adapter
  # plumbing behind health(), not part of the Adapter interface (hard rule 2).
  #
  #   probe: { tcp: 5432 }
  #   probe: { http: "http://127.0.0.1:3000/up" }
  module Probe
    CONNECT_TIMEOUT = 0.25
    READ_TIMEOUT = 0.5

    # true when the probe answers (or the spec declares no probe).
    def self.answering?(spec)
      probe = spec.opts[:probe] or return true
      if (port = probe[:tcp])
        tcp?(port)
      elsif (url = probe[:http])
        http?(url)
      else
        raise ConfigError, "#{spec.id}: probe must be {tcp: PORT} or {http: URL}, got #{probe.inspect}"
      end
    end

    def self.tcp?(port, host = "127.0.0.1")
      Socket.tcp(host, port, connect_timeout: CONNECT_TIMEOUT) { true }
    rescue SystemCallError, IO::TimeoutError
      false
    end

    def self.http?(url)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, open_timeout: CONNECT_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.get(uri.path.empty? ? "/" : uri.path).code.to_i.between?(200, 299)
      end
    rescue SystemCallError, IO::TimeoutError, Net::OpenTimeout, Net::ReadTimeout, EOFError
      false
    end
  end
end
