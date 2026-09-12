# frozen_string_literal: true
# Example config/supervisor.rb — plain Ruby, no Rails loaded.
strategy :rest_for_one
max_restarts 5, within: 60
backoff :exponential, base: 1, cap: 30

child :web,  adapter: :command, cmd: "bundle exec puma -C config/puma.rb", shutdown: 30
child :jobs, adapter: :command, cmd: "bin/jobs", shutdown: 60
