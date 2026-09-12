# frozen_string_literal: true
source "https://rubygems.org"
gemspec

group :development, :test do
  gem "minitest", "~> 5.25"
  gem "rake", "~> 13.0"
end

group :test do
  # Test-only: real puma exercised by test/puma_adapter_test.rb (PLAN 1.5).
  # Never a runtime dependency — the supervisor stays gem-free (DESIGN §9).
  gem "puma", "~> 6.0"
end
