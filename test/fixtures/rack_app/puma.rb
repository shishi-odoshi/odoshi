# frozen_string_literal: true
# Puma config fixture for the :puma adapter tests. The test picks a free port
# at runtime and passes it both here (via env) and to the adapter (opts[:port]).
# Single mode (no workers) on loopback only — simple and un-flaky.
rackup File.expand_path("config.ru", __dir__)
bind "tcp://127.0.0.1:#{ENV.fetch("PUMA_TEST_PORT")}"
