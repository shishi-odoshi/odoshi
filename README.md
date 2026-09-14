# odoshi

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
  gem "odoshi"
end
```

```
$ bundle install
$ odoshi version
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
$ odoshi check config/supervisor.rb   # validate config, print the tree
$ odoshi run   config/supervisor.rb   # supervise (Ctrl-C drains and stops)
```

## Config reference

Top-level directives in `config/supervisor.rb`:

| Directive | Default | Meaning |
|---|---|---|
| `strategy KIND` | `:one_for_one` | `:one_for_one` restarts only the failed child; `:rest_for_one` also restarts children declared after it; `:one_for_all` restarts every child |
| `max_restarts N, within: S` | `5, within: 60` | Sliding-window restart intensity; exceeding it escalates (exit 70) |
| `backoff KIND, **opts` | `:exponential, base: 1, cap: 30` | `:none`, `:constant`, or `:exponential` delay between restarts |
| `socket PATH` | `"tmp/odoshi.sock"` | Heartbeat/control Unix socket; `socket nil` disables it |
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
plugin :odoshi
```

The master then heartbeats worker state over the socket: any missing worker is reported
`"degraded"` (⇒ `[:odoshi, :child, :degraded]` telemetry, `meta: {workers:, booted:,
phase:}`) while puma replaces the worker itself — visibility only, no lifecycle change.
Both adapters export `ODOSHI_CHILD_ID` so plugins and hooks heartbeat under the right id.

## Health & heartbeats

Passive children are probed (PID, TCP, HTTP). Active children report themselves: the
supervisor listens on a Unix socket (mode 0600) and exports `ODOSHI_SOCK` /
`ODOSHI_TOKEN` to every child. Heartbeats are newline-delimited JSON:

```json
{"id":"jobs","state":"healthy","ts":1757700000,"token":"…","meta":{"backlog":0}}
```

A child that has heartbeated is judged by heartbeat freshness: 3 missed `health_interval`s
⇒ `:degraded`, 6 ⇒ `:dead` ⇒ the strategy applies. Wrong token, non-string fields, or
lines over 64 KiB ⇒ silently dropped. The same socket accepts
`{"cmd":"restart","id":"jobs","token":"…"}` — a control restart is deliberate remediation
(DESIGN §7: restarting is a feature), so it does not count toward restart intensity.

From any child process (a Rails initializer, a Solid Queue hook — no Rails required):

```ruby
require "odoshi/heartbeat"   # loads nothing else
Odoshi::Heartbeat.start(id: "jobs")  # no-op when running unsupervised
```

## Telemetry reference

Event names follow `[:odoshi, :subject, :action]`, mirroring Elixir `:telemetry` so the
sidecar can forward them unchanged. This list is a published contract:

```
[:odoshi, :supervisor, :start]     metadata: {strategy, children}
[:odoshi, :supervisor, :stop]
[:odoshi, :supervisor, :escalate]  measurements: {restarts}  metadata: {within}
[:odoshi, :child, :spawn]          metadata: {id, adapter, pid}
[:odoshi, :child, :healthy]        metadata: {id}
[:odoshi, :child, :degraded]       measurements: {consecutive}  metadata: {id}
[:odoshi, :child, :exit]           measurements: {exit_code, uptime_ms}  metadata: {id}
[:odoshi, :child, :restart]        measurements: {backoff_ms}  metadata: {id, attempt, strategy}
[:odoshi, :child, :drain]          metadata: {id}
[:odoshi, :child, :kill]           metadata: {id}  (drain timed out)
```

Subscribe in-process with `Odoshi::Telemetry.subscribe { |event| ... }`; a logger
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
- Compound commands (`cmd: "a && b"`) run under an `sh` wrapper. Drain and kill signal the
  whole process group, so supervised shutdown covers the real workload — but SIGKILL-of-
  the-supervisor orphan prevention (pdeathsig) arms only the wrapper: on Linux the wrapper
  gets SIGTERM and its children are orphaned. Prefer single-exec commands for children
  that must never outlive the supervisor.

## Development

```
bundle exec rake test                        # full suite (real processes, no mocks)
ruby -Ilib -Itest test/supervisor_kill_test.rb
exe/odoshi check examples/supervisor.rb
```

`docs/PLAN.md` is the backlog; `docs/DESIGN.md` is the frozen design.
