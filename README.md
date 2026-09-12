# otp-rails

OTP-style supervision trees for the processes of a Rails app. A slim supervisor — it never
loads Rails — that starts, links, health-checks, and restarts `web`, `jobs`, `cable`, `cron`
with `one_for_one` / `rest_for_one` / `one_for_all` strategies, restart intensity, and backoff.

Part of the [shishi-odoshi](https://github.com/shishi-odoshi) org. Design: `docs/DESIGN.md`.

```ruby
# config/supervisor.rb — plain Ruby, no Rails
strategy :rest_for_one
max_restarts 5, within: 60
child :web,  adapter: :command, cmd: "bundle exec puma -C config/puma.rb"
child :jobs, adapter: :command, cmd: "bin/jobs"
```

```
$ otp-rails check   # print the tree
$ otp-rails run     # supervise
```

Status: pre-0.1 skeleton. `docs/PLAN.md` lists what's built and what's next.
