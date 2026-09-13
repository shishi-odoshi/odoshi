# otp-rails

OTP-style supervision trees for the processes of a Rails app. A slim supervisor — it never
loads Rails — that starts, links, health-checks, and restarts `web`, `jobs`, `cable`, `cron`
with `one_for_one` / `rest_for_one` / `one_for_all` strategies, restart intensity, and backoff.

Part of the [shishi-odoshi](https://github.com/shishi-odoshi) org. Design: `docs/DESIGN.md`.
The Elixir sidecar speaking the same wire protocol lives at
[shishi-odoshi/beam](https://github.com/shishi-odoshi/beam).

## Install

```ruby
# Gemfile — the supervisor is its own process; a :supervisor group keeps app boot slim
group :supervisor do
  gem "otp-rails"
end
```

```
$ bundle install
$ otp-rails version
```

Zero runtime dependencies. Ruby >= 3.2.

## Quick start

```ruby
# config/supervisor.rb — plain Ruby, evaluated WITHOUT Rails
strategy :rest_for_one
max_restarts 5, within: 60
backoff :exponential, base: 1, cap: 30

child :web,  adapter: :puma, port: 3000
child :jobs, adapter: :solid_queue, shutdown: 60
child :cron, adapter: :command, cmd: "bin/rails cron", restart: :transient
```

```
$ otp-rails check config/supervisor.rb   # validate config, print the tree
$ otp-rails run   config/supervisor.rb   # supervise (Ctrl-C drains and stops)
```

## Config reference

Top-level directives in `config/supervisor.rb`:

| Directive | Default | Meaning |
|---|---|---|
| `strategy KIND` | `:one_for_one` | `:one_for_one` restarts only the failed child; `:rest_for_one` also restarts children declared after it; `:one_for_all` restarts every child |
| `max_restarts N, within: S` | `5, within: 60` | Sliding-window restart intensity; exceeding it escalates (exit 70) |
| `backoff KIND, **opts` | `:exponential, base: 1, cap: 30` | `:none`, `:constant`, or `:exponential` delay between restarts |
| `socket PATH` | `"tmp/otp-rails.sock"` | Heartbeat/control Unix socket; `socket nil` disables it |
| `child ID, adapter:, **opts` | — | Declares a child; declaration order is start order |
| `supervisor ID do ... end` | — | Nested subtree with its own strategy/intensity/backoff; subtree escalation is an ordinary child exit in the parent |

Per-child options:

| Option | Default | Meaning |
|---|---|---|
| `restart:` | `:permanent` | `:permanent` always restarts; `:transient` restarts only on non-zero exit; `:temporary` never restarts |
| `shutdown:` | `30` | Seconds to wait after SIGTERM before SIGKILL of the child's process group |
| `start_timeout:` | `30` | Seconds to reach `:healthy`; exceeding it drains the child and counts as a crash |
| `health_interval:` | `5` | Seconds between health checks (and the unit for heartbeat freshness) |
| `degraded_restart_after:` | `nil` | N consecutive `:degraded` reports ⇒ drain and restart (counts toward intensity) |

Adapters:

- **`:command`** — any command. `cmd:` (required), `env:`, `spawn_opts:`, and optional
  `probe: { tcp: PORT }` or `probe: { http: "http://127.0.0.1:3000/up" }` — the child is
  `:starting` until the probe answers, `:degraded` if it stops answering later.
- **`:puma`** (beside mode) — wraps the puma master. `config:` (default `config/puma.rb`),
  `port:` (or a literal `port NNNN` line in the config). Health = HTTP probe of `/up`;
  drain = SIGTERM (Puma's graceful stop).
- **`:solid_queue`** — wraps `bin/jobs` (`cmd:` overrides). Health = the active heartbeat
  below, never the `solid_queue_processes` table.

For worker-level visibility on a cluster-mode `:puma` child, add the plugin to
`config/puma.rb`:

```ruby
plugin :otp_rails
```

The master then heartbeats worker state over the socket: any missing worker is reported
`"degraded"` (⇒ `[:otp_rails, :child, :degraded]` telemetry, `meta: {workers:, booted:,
phase:}`) while puma replaces the worker itself — visibility only, no lifecycle change.
Both adapters export `OTP_RAILS_CHILD_ID` so plugins and hooks heartbeat under the right id.

## Health & heartbeats

Passive children are probed (PID, TCP, HTTP). Active children report themselves: the
supervisor listens on a Unix socket (mode 0600) and exports `OTP_RAILS_SOCK` /
`OTP_RAILS_TOKEN` to every child. Heartbeats are newline-delimited JSON:

```json
{"id":"jobs","state":"healthy","ts":1757700000,"token":"…","meta":{"backlog":0}}
```

A child that has heartbeated is judged by heartbeat freshness: 3 missed `health_interval`s
⇒ `:degraded`, 6 ⇒ `:dead` ⇒ the strategy applies. Wrong token ⇒ the line is silently
dropped. The same socket accepts `{"cmd":"restart","id":"jobs","token":"…"}`.

From any child process (a Rails initializer, a Solid Queue hook — no Rails required):

```ruby
require "otp_rails/heartbeat"   # loads nothing else
OtpRails::Heartbeat.start(id: "jobs")  # no-op when running unsupervised
```

## Telemetry reference

Event names follow `[:otp_rails, :subject, :action]`, mirroring Elixir `:telemetry` so the
sidecar can forward them unchanged. This list is a published contract:

```
[:otp_rails, :supervisor, :start]     metadata: {strategy, children}
[:otp_rails, :supervisor, :stop]
[:otp_rails, :supervisor, :escalate]  measurements: {restarts}  metadata: {within}
[:otp_rails, :child, :spawn]          metadata: {id, adapter, pid}
[:otp_rails, :child, :healthy]        metadata: {id}
[:otp_rails, :child, :degraded]       measurements: {consecutive}  metadata: {id}
[:otp_rails, :child, :exit]           measurements: {exit_code, uptime_ms}  metadata: {id}
[:otp_rails, :child, :restart]        measurements: {backoff_ms}  metadata: {id, attempt, strategy}
[:otp_rails, :child, :drain]          metadata: {id}
[:otp_rails, :child, :kill]           metadata: {id}  (drain timed out)
```

Subscribe in-process with `OtpRails::Telemetry.subscribe { |event| ... }`; a logger
subscriber and a JSON-lines exporter ship by default (`Telemetry::Subscribers`).

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Clean stop (SIGINT/SIGTERM, all children drained) |
| `70` | Restart intensity exceeded — the supervisor escalated (EX_SOFTWARE). The platform (Kamal/K8s/Heroku/launchd) is the final supervisor and should restart on non-zero |
| `78` | Configuration error (EX_CONFIG) |

## Shutdown semantics

- `stop_all` drains children in **reverse start order**, waiting for each child to exit
  (up to its `shutdown:` timeout, then SIGKILL of its process group) before draining the next.
- Orphan prevention: on Linux, children are armed with `prctl(PR_SET_PDEATHSIG, SIGTERM)`
  between fork and exec, so they receive SIGTERM even if the supervisor is SIGKILLed.
  **macOS/BSD limitation:** no parent-death signal exists there; a SIGKILLed supervisor
  orphans its children to launchd/init and they keep running. Mitigation: the platform
  restarts the supervisor; each child runs in its own session/process group, so stale
  orphans are findable and killable by pgid.
- macOS also caps Unix socket paths at ~104 bytes — keep `socket PATH` short.

## Development

```
bundle exec rake test                        # full suite (real processes, no mocks)
ruby -Ilib -Itest test/supervisor_kill_test.rb
exe/otp-rails check examples/supervisor.rb
```

`docs/PLAN.md` is the backlog; `docs/DESIGN.md` is the frozen design.
