# frozen_string_literal: true

require_relative "lib/otp_rails/version"

Gem::Specification.new do |s|
  s.name        = "otp-rails"
  s.version     = OtpRails::VERSION
  s.summary     = "OTP-style supervision trees for Rails processes"
  s.description = "A slim supervisor that starts, links, health-checks, and restarts the " \
                  "processes of a Rails app (web, jobs, cable, cron) with OTP strategies."
  s.authors     = ["timimsms"]
  s.license     = "MIT"
  s.homepage    = "https://github.com/shishi-odoshi/otp-rails"
  s.metadata    = {
    "homepage_uri"    => s.homepage,
    "source_code_uri" => s.homepage,
    "changelog_uri"   => "#{s.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{s.homepage}/issues"
  }
  s.required_ruby_version = ">= 3.2"
  s.files       = Dir["lib/**/*.rb", "exe/*", "README.md", "CHANGELOG.md", "LICENSE"]
  s.bindir      = "exe"
  s.executables = ["otp-rails"]
  # Deliberately no runtime dependencies: the supervisor must stay slim (DESIGN §9).
end
