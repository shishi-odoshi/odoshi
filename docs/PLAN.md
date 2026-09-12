# otp-rails — Build Plan

Work items in order. Each has an acceptance test. Tick when green and committed.
Reference: `docs/DESIGN.md` (§ numbers below point there).

## Already built (skeleton, 12 passing tests)

- [x] `ChildSpec` with permanent/transient/temporary restart semantics (§3.2)
- [x] `Strategy.affected` for one_for_one / rest_for_one / one_for_all (§3.3)
- [x] `RestartIntensity` with sliding window + `Backoff` (none/constant/exponential)
- [x] `Adapter` interface + registry; `:command` adapter (spawn/link/health=PID/drain=TERM/kill=KILL pgroup)
- [x] `Supervisor` loop: ordered start, link callbacks via queue, exit handling with generation
      guard (stale exits ignored), strategy fan-out, escalation raises `Escalation`
- [x] `Telemetry` bus with the §6 event names; logger + JSON-lines subscribers
- [x] DSL loader for `config/supervisor.rb`; CLI `run | check | version`
- [x] Kill tests: killed child restarts; rest_for_one restarts siblings; intensity escalates

## Phase 1 — `otp-rails` 0.1

### 1.1 Shutdown correctness
- [x] `stop_all` drains children in reverse start order and waits for each before the next.
- [x] Supervisor exits non-zero (70) on escalation, zero on clean stop; CLI honors both.
- [x] Orphan prevention: if the supervisor itself is SIGKILLed, children get SIGTERM.
      Implement via `Process.setsid` + prctl-style parent-death signal where available, else
      document the limitation. Test: kill -9 the supervisor, assert children exit within 5s.
- Accept: new tests in `test/shutdown_test.rb` green on Linux and macOS.
- Notes: Linux gets `fork → setsid → prctl(PR_SET_PDEATHSIG, SIGTERM) → exec` (fiddle, stdlib);
  macOS has no parent-death signal — documented in README, test skips there. CI matrix now
  includes macos-latest (acceptance requires green on both, the skeleton only ran ubuntu).

### 1.2 Probes for `:command` (§4.1)
- [x] `probe: { tcp: PORT }` — `:starting` until a TCP connect succeeds, then `:healthy`.
- [x] `probe: { http: "http://127.0.0.1:3000/up" }` — `:starting` until 2xx. Net::HTTP is
      stdlib, so allowed.
- [x] `start_timeout` exceeded ⇒ drain, count as a crash, apply strategy. Test with a script
      that never opens its port.
- Accept: `test/probe_test.rb` using a fixture Ruby TCP server under `test/fixtures/`.
- Notes: probes live in `Probe` (lib/otp_rails/probe.rb) behind `Command#health` — the
  Adapter interface is unchanged. start_timeout ⇒ `stop_child`; the drained exit flows
  through the normal link → handle_exit path, so intensity/strategy apply with no new code.

### 1.3 Periodic health loop (§5)
- [x] `health_interval` (default 5s) polling thread per child; `:degraded` emits telemetry only;
      `:dead` from a probe (not just SIGCHLD) triggers the strategy. Reuse the exit queue.
- [x] Config knob `degraded_restart_after: N` (default nil) — N consecutive `:degraded` ⇒ restart.
- Accept: test with a fixture that starts answering 503 after a flag file appears.
- Notes: monitor thread per child, started only once the child reached `:healthy`; stale
  threads self-terminate via the generation guard. Probe-dead and degraded-threshold both
  enqueue `:health_dead`, whose handler drains the child so the real exit flows through
  link → handle_exit — i.e. the degraded restart counts toward intensity and the strategy
  (same single crash path as the 1.2 start_timeout drain; prevents silent restart-flapping).
  `:command` reports `:degraded` when a probe stops answering after having answered once.

### 1.4 Active heartbeat socket (§5, §9)
- [x] Supervisor listens on a Unix socket (`tmp/otp-rails.sock`, mode 0600). Path and a per-boot
      token are passed to children via `OTP_RAILS_SOCK` / `OTP_RAILS_TOKEN` env.
- [x] Children write NDJSON heartbeats: `{"id","state","ts","token","meta"}`. Bad token ⇒ dropped.
- [x] A child that heartbeats is `active`; missing 3 intervals ⇒ `:degraded`, 6 ⇒ `:dead`.
- [x] Control messages on the same socket: `{"cmd":"restart","id":"jobs","token":...}`.
      This is the transport for `Rails.supervisor.restart!` later.
- Accept: `test/socket_test.rb` — a fixture child heartbeats; stop it heartbeating; assert restart.
- Notes: `SocketServer` (NDJSON only, token checked at the socket layer, silent drops).
  Env is exported in the supervisor process before children start, so every adapter inherits
  it with no interface change. Heartbeat freshness/state feeds `effective_health`: active
  children are judged by heartbeats (child-reported state, 3/6-interval aging), passive
  children fall back to adapter probes; heartbeat-`:dead` reuses the 1.3 `:health_dead` →
  drain → crash path. Heartbeats are cleared on respawn so a replaced child can't vouch for
  its successor. DSL gains `socket PATH` (default `tmp/otp-rails.sock`; `socket nil` disables —
  the CLI shutdown tests use that, since Unix sockets can't bind on some mounted filesystems).

### 1.5 `:puma` adapter, beside mode (§4.2 step 1)
- [x] Wraps `bundle exec puma -C config/puma.rb`. Health = HTTP probe of `/up` (Rails 7.1+
      default) on the bound port parsed from `config/puma.rb` or `opts[:port]`.
- [x] Drain = SIGTERM (Puma graceful). `shutdown:` default 30.
- Accept: test against a 10-line Rack app under `test/fixtures/rack_app/` with puma as a
      **test-only** dependency. Kill puma master; assert restart; assert `/up` answers again.
- Notes: `Adapters::Puma < Command` — spawn builds a derived ChildSpec (puma cmd +
  `probe: {http: ".../up"}`), so health/link/drain/kill are all inherited via the 1.2
  Probe path; zero new supervisor code. Port resolution: `opts[:port]` wins, else a
  literal `port NNNN` line parsed from the config file, else ConfigError (raised before
  anything spawns; ENV/ERB ports in the config must pass `opts[:port]`). Fixture puma
  runs single mode on loopback; the test picks a free port at runtime. Beside-mode
  observation for the §4.2 step-2 gate: kill -9 of a *cluster* master would orphan
  workers that keep the port bound until they notice the master died — single mode
  sidesteps it, cluster mode needs worker-level visibility (the step-2 plugin).

### 1.6 `:solid_queue` adapter
- [x] Wraps `bin/jobs` (Solid Queue supervisor). Health = active heartbeat from 1.4 sent by a
      tiny hook, **not** the DB table (§9). Provide `lib/otp_rails/heartbeat.rb` — a
      Rails-free helper any child can require to send heartbeats.
- Accept: fixture child using `Heartbeat`; kill it; assert restart.
- Notes: `Heartbeat` is deliberately self-contained (`require "otp_rails/heartbeat"` loads
  nothing else) so app initializers/hooks stay featherweight; it silently no-ops when
  OTP_RAILS_SOCK is absent (unsupervised dev runs must not error) and reconnects on socket
  loss without ever raising into the host. Adapter follows the 1.5 derived-spec pattern:
  Command with cmd defaulted to `bin/jobs`; drain stays SIGTERM (Solid Queue's own graceful
  stop). Passive PID health remains the pre-first-heartbeat fallback via `effective_health`.

### 1.7 Nested supervisors (§3.1)
- [x] `supervisor :background do ... end` in the DSL creates a subtree with its own strategy
      and intensity; escalation from a subtree is an exit of that child in the parent.
- Accept: test where a subtree exceeds intensity and the parent restarts the whole subtree.
- Notes: a subtree is an ordinary child via a `:supervisor` pseudo-adapter
  (`Adapters::SupervisorAdapter`) — the handle wraps a child `Supervisor` running `run` on a
  Thread; the Adapter interface is untouched. `Escalation` in the thread is caught by the link
  waiter and reported as a crashed exit (exitstatus 70), so the parent's existing
  handle_exit → strategy/intensity path applies with zero new supervisor code. The subtree's
  `run` `ensure stop_all` drains its own children before the thread dies, so an escalated
  subtree leaves no orphan PIDs (asserted in tests). The DSL keeps the nested block as a
  **builder proc** and re-evaluates it on every (re)start: RestartIntensity is stateful, and a
  restarted subtree must get a fresh instance / fresh intensity window — reusing the old
  Supervisor would make the subtree re-escalate immediately. Subtree specs get
  `health_interval: nil` (no probe monitor in the parent; thread death arrives via link) and
  subtrees never bind their own heartbeat socket — only the root listens; `socket` inside a
  nested block raises ConfigError. Heartbeat ids stay flat/global for now (see Open questions).

### 1.8 Release
- [ ] `CHANGELOG.md`, `bundle exec rake build`, tag `v0.1.0`, push to RubyGems.
- [ ] README: install, config reference, telemetry reference, exit codes.

## Phase 2 — `otp-rails-template` (separate repo, after 1.8)
- `rails new --template` script adding the gem, `config/supervisor.rb`, `bin/supervise`,
  `rake chaos:kill[child]` tasks, and a CI job that runs each chaos task and asserts recovery < 10s.

## Phase 2.5 — Puma plugin (§4.2 step 2)
- `lib/puma/plugin/otp_rails.rb` using `on_worker_boot/shutdown` to send worker-level heartbeats
  over the 1.4 socket. Adds `[:otp_rails, :child, :degraded]` when a worker is missing.

## Phase 3 — `otp-rails-resilience` (separate repo)
- Railtie bridging Telemetry → ActiveSupport::Notifications; `Rails.supervisor.restart!` over
  the socket; breaker defaults for AR pool / Net::HTTP / Redis; `bin/rails boot:check`.

## Phase 4 — `beam` (Elixir, separate repo)
- Ports-based supervisor consuming §5 NDJSON; then GoodJob-Elixir shared queue; then Phoenix channels.

## Open questions (add here, don't guess)

- **fiddle leaves the default gems in Ruby 3.5** (warns on 3.4). Orphan prevention (1.1) uses
  stdlib fiddle for `prctl(PR_SET_PDEATHSIG)` on Linux. On Ruby 3.5+ without the fiddle gem,
  `OrphanGuard.available?` returns false and we silently fall back to plain spawn (same
  behavior as macOS). Options: (a) accept the graceful degradation — platform-as-final-
  supervisor already covers it; (b) add `fiddle` as a runtime dependency — violates hard
  rule 1 (zero dependencies); (c) tiny optional C extension. Recommendation: (a) for 0.1,
  revisit when CI adds Ruby 3.5.

- **Heartbeat ids are flat/global across nested supervisors (1.7).** Only the root binds the
  socket, and heartbeats key on the bare child id — so a grandchild heartbeating as `"jobs"`
  lands in the ROOT's freshness table, not the subtree that owns `:jobs`, and duplicate ids
  across sibling subtrees (legal today — uniqueness is per-tree) would collide. Options:
  (a) keep flat ids; document "ids must be unique tree-wide when using heartbeats";
  (b) path-qualified ids (`"background.jobs"`) — touches the §5 NDJSON contract beam consumes;
  (c) root forwards heartbeats to the owning subtree. Recommendation: (a) for 0.1; revisit
  (b) only with a DESIGN §5 edit if beam needs subtree-scoped visibility.

## Surprises log

- (record anything that contradicted DESIGN.md or cost more than an hour)
- 1.1 — `Process.kill(0, pid)` succeeds on zombies. The orphan test originally asserted
  "child pid gone within 5s", which false-fails anywhere PID 1 doesn't promptly reap
  reparented orphans (Docker, bare containers). pdeathsig itself worked the whole time.
  Fixed by having the fixture child write a marker file from its TERM handler — assert
  signal delivery, not process disappearance.
