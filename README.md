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

## Shutdown semantics

- `stop_all` drains children in **reverse start order**, waiting for each child to exit
  (up to its `shutdown:` timeout, then SIGKILL of its process group) before draining the next.
- Exit codes: `0` clean stop · `70` (EX_SOFTWARE) restart intensity exceeded, supervisor
  escalated · `78` (EX_CONFIG) config error. The platform (Kamal/K8s/Heroku/launchd) is the
  final supervisor and should restart on non-zero.
- Orphan prevention: on Linux, children are armed with `prctl(PR_SET_PDEATHSIG, SIGTERM)`
  between fork and exec, so they receive SIGTERM even if the supervisor is SIGKILLed.
  **macOS/BSD limitation:** no parent-death signal exists there; a SIGKILLed supervisor
  orphans its children to launchd/init and they keep running. Mitigation: the platform
  restarts the supervisor; each child runs in its own session/process group, so stale
  orphans are findable and killable by pgid.

Status: pre-0.1 skeleton. `docs/PLAN.md` lists what's built and what's next.
