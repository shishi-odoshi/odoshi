# frozen_string_literal: true
# Minimal Rack app for the :puma adapter tests. /up mirrors the Rails 7.1+
# default health endpoint the adapter probes.
run lambda { |env|
  if env["PATH_INFO"] == "/up"
    [200, { "content-type" => "text/plain" }, ["OK"]]
  else
    [404, { "content-type" => "text/plain" }, ["not found"]]
  end
}
