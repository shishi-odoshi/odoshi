# frozen_string_literal: true
# Single-mode puma serving the wedgeable app, with the odoshi plugin — the
# issue #49 configuration: heartbeats AND a failable /up on the same child.
rackup File.expand_path("config_flaky.ru", __dir__)
bind "tcp://127.0.0.1:#{ENV.fetch("PUMA_TEST_PORT")}"
plugin :odoshi
