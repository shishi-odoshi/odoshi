# frozen_string_literal: true
# Cluster-mode puma config fixture for the odoshi plugin tests: two
# workers, NO preload — each worker pays the app's BOOT_DELAY, so a killed
# worker leaves a measurable booted < workers window (as in a real Rails app).
rackup File.expand_path("config_slow.ru", __dir__)
bind "tcp://127.0.0.1:#{ENV.fetch("PUMA_TEST_PORT")}"
workers 2
worker_shutdown_timeout 2
plugin :odoshi
