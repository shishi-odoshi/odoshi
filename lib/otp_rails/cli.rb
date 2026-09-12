# frozen_string_literal: true
module OtpRails
  module CLI
    USAGE = <<~TXT
      usage: otp-rails run   [config/supervisor.rb]   # start the tree, block until shutdown
             otp-rails check [config/supervisor.rb]   # validate config, print the tree
             otp-rails version
    TXT

    def self.run(argv)
      cmd, path = argv[0], (argv[1] || "config/supervisor.rb")
      case cmd
      when "run"
        Telemetry::Subscribers.logger
        sup = DSL.load_file(path)
        %w[INT TERM].each { |sig| trap(sig) { sup.stop } }
        sup.run
        0
      when "check"
        sup = DSL.load_file(path)
        puts "strategy: #{sup.strategy}"
        sup.children.each { |c| puts "  #{c.id} (#{c.adapter}, #{c.restart}, shutdown=#{c.shutdown}s)" }
        0
      when "version" then puts VERSION; 0
      else $stderr.puts USAGE; 1
      end
    rescue Escalation => e
      $stderr.puts "otp-rails: #{e.message}"; 70 # EX_SOFTWARE — the platform is the final supervisor
    rescue ConfigError, Errno::ENOENT => e
      $stderr.puts "otp-rails: #{e.message}"; 78 # EX_CONFIG
    end
  end
end
