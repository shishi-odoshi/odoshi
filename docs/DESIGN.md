# otp-rails — Phase 0 Design

Status: draft v0.1 · Owner: Tim · Decision log at bottom

## 1. Thesis

Bring OTP-style supervision, crash-only design, and built-in resilience to Rails
without forking Rails. Ship as gems that install into any Rails 8 app, prove them in
a reference template, and expose protocols simple enough that an Elixir/Phoenix
sidecar can act as an alternate supervisor and job runner.

Non-goals: hot code loading, preemptive scheduling, replacing Puma in v1.

## 2. Repos

| Repo | Type | Purpose |
|---|---|---|
| `supervisor` | gem | Supervision tree, child specs, adapters, telemetry |
| `resilience` | gem | Breakers/bulkheads wired into AR, Net::HTTP, Redis; crash-only conventions |
| `template` | app | `rails new --template` reference app + chaos tests |
| `beam` | Elixir app | Ports-based supervision of Rails processes, shared-DB jobs, Phoenix channels |

Dependency direction: `template` → `resilience` → `supervisor`. `beam` depends only
on the protocols in §5–§6 and the DB schema, never on Ruby code.

## 3. Core model

### 3.1 Supervisor
Declared in `config/supervisor.rb` (loaded after `application.rb`, before initializers run
in child processes):

```ruby
Rails.supervisor do
  strategy :rest_for_one
  max_restarts 5, within: 60.seconds
  backoff :exponential, base: 1.second, cap: 30.seconds

  child :web,   adapter: :puma
  child :cable, adapter: :command, cmd: "bin/rails cable:server"
  child :jobs,  adapter: :solid_queue, workers: 4
  child :cron,  adapter: :command, cmd: "bin/rails cron"
end
```

Order of declaration is start order and defines `rest_for_one` semantics.
Supervisors nest: `supervisor :background do ... end` creates a subtree.

### 3.2 ChildSpec
```
id:            Symbol, unique within tree
adapter:       Symbol → registered Adapter class
restart:       :permanent (default) | :transient | :temporary
shutdown:      Integer seconds to wait after drain before SIGKILL (default 30)
start_timeout: Integer seconds to reach :healthy before counted as a failed start
opts:          adapter-specific
```

### 3.3 Strategies
- `one_for_one` — restart only the failed child.
- `rest_for_one` — restart the failed child and all children declared after it.
- `one_for_all` — restart every child in the subtree.

Restart intensity follows OTP: if more than `max_restarts` occur `within` the window,
the supervisor itself exits, escalating to its parent. The root supervisor exiting
terminates the process with a non-zero code — the platform (Kamal/K8s/Heroku) is the
final supervisor, which is intentional.

## 4. Adapter interface

Every child, regardless of what it wraps, implements exactly four operations:

```ruby
class Adapter
  def spawn(spec)  -> Handle    # start the child, return an opaque handle
  def link(handle, &on_exit)    # register callback invoked with exit status
  def health(handle) -> :starting | :healthy | :degraded | :dead
  def drain(handle, timeout:)   # stop accepting work, finish in-flight, exit
end
```

Rules:
- `spawn` must be idempotent-safe: calling it twice for the same spec while a
  handle is live is an error, not a second process.
- `link` must fire exactly once per handle lifetime.
- `drain` returning without the child exiting within `timeout` results in SIGKILL.
- Adapters never call each other. Coordination goes through the supervisor.

### 4.1 Built-in adapters (v0.1)
- `:command` — arbitrary command. Health = PID alive + optional TCP/HTTP probe.
- `:puma` (beside mode) — wraps `puma` cluster master. Health = HTTP probe of
  `/up` on the bound socket; drain = SIGTERM.
- `:solid_queue` — wraps the Solid Queue supervisor process. Health = PID + heartbeat
  row freshness in `solid_queue_processes`.

### 4.2 Puma roadmap
1. **Beside** (v0.1): one opaque child. Ships first.
2. **Beside + plugin** (v0.2): a Puma plugin using `on_worker_boot` /
   `on_worker_shutdown` / `on_worker_fork` to emit worker-level telemetry (§6) to the
   supervisor over a Unix socket. Adds visibility, changes no lifecycle.
3. **Owned** (experimental, feature-flagged): supervisor forks workers directly.
   Gated on step 2 exposing a concrete limitation. Acceptance bar = template chaos
   suite passes with the owned adapter for 30 days in CI.

## 5. Health protocol

A child is queried by the supervisor at `health_interval` (default 5s). Two ways a
child reports:

- **Passive** — the adapter probes (PID, HTTP `/up`, DB heartbeat).
- **Active** — the child writes a heartbeat to a Unix socket the supervisor listens on.
  Message format is newline-delimited JSON:

```json
{"id":"web","state":"healthy","ts":1757700000,"token":"<OTP_RAILS_TOKEN>","meta":{"workers":4,"backlog":0}}
```

Wire rules (each violated line is silently dropped, exactly like a bad token):
- Every message carries `token` — the per-boot value from `OTP_RAILS_TOKEN`.
- `token`, `id`, `state`, and `cmd` are JSON strings; non-string values are malformed.
- A line is at most 64 KiB including the newline; longer is malformed (receivers drop
  the oversized line and resume at the next newline, memory stays bounded).
- `ts` is informational only: freshness is measured at receipt by the supervisor's
  monotonic clock, never from `ts`.

State transitions:
- `starting → healthy` within `start_timeout`, else counted as a crash.
- `healthy → degraded` does not trigger restart; emits telemetry only. Adapters may
  optionally trigger a drain-and-restart after N consecutive `degraded` reports.
- Any `→ dead` triggers the strategy.

This JSON protocol is the contract the `beam` repo consumes. Keep it boring.

## 6. Telemetry

Event names follow `[:otp_rails, :subject, :action]`, mirroring Elixir `:telemetry`
so the sidecar can forward them unchanged.

```
[:otp_rails, :supervisor, :start]
[:otp_rails, :supervisor, :stop]
[:otp_rails, :supervisor, :escalate]       # intensity exceeded
[:otp_rails, :child, :spawn]
[:otp_rails, :child, :healthy]
[:otp_rails, :child, :degraded]
[:otp_rails, :child, :exit]                # measurements: {exit_code, uptime_ms}
[:otp_rails, :child, :restart]             # metadata:     {attempt, backoff_ms, strategy}
[:otp_rails, :child, :drain]
[:otp_rails, :child, :kill]                # drain timed out
```

Ruby API: `ActiveSupport::Notifications` under the hood; a `Rails.supervisor.subscribe`
convenience on top. A default logger subscriber and a JSON-lines exporter ship in v0.1.

## 7. Crash-only conventions (resilience gem, but constrain design now)

- Boot must be idempotent: `bin/rails boot:check` verifies no initializer writes to
  shared state that would break on double-run.
- No in-process cross-request state. A `Rails.supervisor.state_guard` raises in
  development/test when a class-level ivar is written after boot.
- `Rails.supervisor.restart!(:jobs)` is cheap, public, and the recommended remediation
  in runbooks — restarting is a feature, not a failure.
- Breakers default to fail-open storage (Faulty's rule): if the breaker's own
  backend dies, circuits open rather than the app hanging.

## 8. Phases and acceptance criteria

| Phase | Deliverable | Done when |
|---|---|---|
| 0 | This doc, §3–§6 frozen | Reviewed; `beam` maintainer (future you) can implement §5 from it alone |
| 1 | `supervisor` 0.1 | `:command` + `:puma` (beside) + `:solid_queue`; `one_for_one` and `rest_for_one`; kill-tests in CI |
| 2 | `template` | `rails new` template; `rake chaos:*` tasks kill each child and assert recovery under 10s |
| 2.5 | Puma plugin | Worker-level events visible in telemetry stream |
| 3 | `resilience` 0.1 | AR pool + Net::HTTP + Redis breakers on by default; boot:check task |
| 4 | `beam` | Ports supervision of Rails children using §5; then GoodJob-Elixir shared queue; then Phoenix channels |

## 9. Slim supervisor — constraints (RESOLVED: slim)

The supervisor is a separate process that never loads the Rails app. It boots via
`Bundler.setup(:supervisor)` in ~100ms and can therefore supervise Rails boot itself.
Consequences, each binding on the design above:

- `config/supervisor.rb` is plain Ruby, evaluated without Rails. Inputs are ENV and
  an optional `config/supervisor.yml`. No `Rails.application.config`, no credentials.
  Custom adapters are `require`d explicitly; no Zeitwerk.
- No ActiveRecord in the supervisor. Health is active-first (§5 socket heartbeat);
  passive probes (PID, HTTP `/up`) are for children that can't cooperate. The
  `:solid_queue` adapter uses the active heartbeat, not the DB table.
- Telemetry (§6) has two halves: the supervisor's own minimal event bus, and a
  railtie inside each child that bridges those events into
  `ActiveSupport::Notifications`. `Rails.supervisor.subscribe` is the child-side API.
- `Rails.supervisor.restart!(:jobs)` from app code is an IPC call over the Unix
  socket. The socket is mode 0600 and requires a per-boot token from ENV; anything
  that can write to it can restart workers.
- Dev mode is opt-in: `config.supervisor.wrap_dev_server = true` makes `rails server`
  spawn the supervisor and run as its `:web` child. Default remains plain Puma.

## 10. Open questions

None blocking Phase 1.
## Decision log

- 2026-09-12 — Gems over fork/boilerplate. Fork only if Rails boot blocks process
  ownership; remedy is an upstream hook PR, not a fork.
- 2026-09-12 — Puma: beside → beside+plugin → owned, each gated on a concrete limitation.
- 2026-09-12 — Health/telemetry protocols are the Elixir contract; no Ruby coupling.
- 2026-09-12 — Supervisor is a slim process that never loads Rails (§9).
- 2026-09-12 — Dev server wrapping is opt-in via `config.supervisor.wrap_dev_server`.
- 2026-09-12 — Name: `otp-rails`. Gems: `otp-rails`, `otp-rails-resilience`; Hex: `otp_rails_beam`.
- 2026-09-12 — GitHub org: `shishi-odoshi` (鹿威し, the self-resetting bamboo fountain). All repos live under it; the org name is not used in gem/Hex names.
- 2026-09-13 — §5 wire rules tightened per the QA pass (Tim's fix directive; issues #21/#22):
  `token` documented in the example (both implementations always required it), string-typed
  fields, 64 KiB line cap, `ts` informational. Behavior was already true in Ruby; beam
  mirrors it. No message shape changed.
