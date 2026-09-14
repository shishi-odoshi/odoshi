# frozen_string_literal: true

require_relative "lib/otp_rails/version"

Gem::Specification.new do |s|
  s.name        = "otp-rails"
  s.version     = OtpRails::VERSION
  s.summary     = "OTP-style supervision trees for Rails processes"
  s.description = "RENAMED: this gem is now `odoshi` (https://rubygems.org/gems/odoshi). " \
                  "otp-rails 0.2.1 is identical to 0.2.0 plus a telemetry hardening fix; " \
                  "all future releases ship as odoshi. See https://github.com/shishi-odoshi/odoshi."
  s.authors     = ["timimsms"]
  s.license     = "MIT"
  s.homepage    = "https://github.com/shishi-odoshi/otp-rails"
  s.metadata    = {
    "homepage_uri"    => s.homepage,
    "source_code_uri" => s.homepage,
    "changelog_uri"   => "#{s.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{s.homepage}/issues"
  }
  s.post_install_message = "otp-rails has been renamed to `odoshi` — https://rubygems.org/gems/odoshi\n" \
                           "otp-rails will receive no further releases. Migration table: CHANGELOG 0.3.0 in the odoshi repo."
  s.required_ruby_version = ">= 3.2"
  s.files       = Dir["lib/**/*.rb", "exe/*", "README.md", "CHANGELOG.md", "LICENSE"]
  s.bindir      = "exe"
  s.executables = ["otp-rails"]
  # Deliberately no runtime dependencies: the supervisor must stay slim (DESIGN §9).
end
