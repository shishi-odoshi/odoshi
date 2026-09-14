# frozen_string_literal: true
# Single-mode puma with the odoshi plugin: the plugin must be a clean
# always-"healthy" heartbeater when there are no workers to count.
rackup File.expand_path("config.ru", __dir__)
bind "tcp://127.0.0.1:#{ENV.fetch("PUMA_TEST_PORT")}"
plugin :odoshi
