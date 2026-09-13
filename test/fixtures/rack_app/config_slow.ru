# frozen_string_literal: true
# Same /up app as config.ru, but each load pays BOOT_DELAY seconds — the
# realistic shape of a Rails app booting in a fresh cluster worker. Gives the
# "worker missing" window a deterministic width for the plugin test.
sleep Float(ENV.fetch("BOOT_DELAY", "0"))
run lambda { |env|
  if env["PATH_INFO"] == "/up"
    [200, { "content-type" => "text/plain" }, ["OK"]]
  else
    [404, { "content-type" => "text/plain" }, ["not found"]]
  end
}
