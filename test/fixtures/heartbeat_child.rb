# frozen_string_literal: true
# Usage: ruby heartbeat_child.rb [ID] [INTERVAL]
# A stand-in for `bin/jobs`: uses the real Odoshi::Heartbeat helper — the
# exact hook a Rails app would call from an initializer — then works forever.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "odoshi/heartbeat"

Odoshi::Heartbeat.start(id: ARGV[0] || "jobs", interval: (ARGV[1] || "0.1").to_f)
sleep 60
