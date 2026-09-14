# frozen_string_literal: true
# The wedged-but-alive app (issue #49): /up serves 200 until the WEDGE_FLAG
# file appears, then 503 — the process stays up and keeps heartbeating.
run lambda { |env|
  wedged = File.exist?(ENV.fetch("WEDGE_FLAG"))
  if env["PATH_INFO"] == "/up" && !wedged
    [200, { "content-type" => "text/plain" }, ["OK"]]
  elsif env["PATH_INFO"] == "/up"
    [503, { "content-type" => "text/plain" }, ["wedged"]]
  else
    [404, { "content-type" => "text/plain" }, ["not found"]]
  end
}
