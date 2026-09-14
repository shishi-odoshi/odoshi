# Changelog

## v0.3.1 — 2026-09-14

Two fixes from odoshi-bench findings:
- **Puma plugin heartbeat no longer masks a wedged app (#49).** Under §5 active-first
  health a "healthy" heartbeat out-votes a failing probe; the plugin's stats-only
  heartbeat therefore silently disabled wedge detection on any :puma child running it.
  The plugin now reports the WORSE of worker topology and a /up probe on the first tcp
  bind (`ODOSHI_HEALTH_URL` overrides; unix-only binds fall back to topology-only), and
  `meta` gains `up: true/false`.
- **Immediate first restart for `:exponential` backoff (odoshi-template#1).** OTP
  convention: a one-off crash costs no delay — the ladder starts at `base` from the
  second consecutive attempt (crash-loops stay bounded by intensity, and a healthy
  interval resets attempts). Benchmarked recovery drops by ~1s under the default config.

## v0.3.0 — 2026-09-13 — RENAMED: otp-rails → odoshi

The gem is now **odoshi** (威し — the active half of [shishi-odoshi](https://github.com/shishi-odoshi),
the self-resetting bamboo fountain). "otp" reads as one-time password in Rubyland; this
project's OTP was always the Erlang kind. Everything renames — **breaking across the board**:

| was | is |
|---|---|
| `gem "otp-rails"` | `gem "odoshi"` |
| `OtpRails::` / `require "otp_rails/…"` | `Odoshi::` / `require "odoshi/…"` |
| `otp-rails run` (CLI) | `odoshi run` |
| `OTP_RAILS_SOCK` / `_TOKEN` / `_CHILD_ID` / `_HEARTBEAT_INTERVAL` | `ODOSHI_SOCK` / `_TOKEN` / `_CHILD_ID` / `_HEARTBEAT_INTERVAL` |
| telemetry `[:otp_rails, …]` | `[:odoshi, …]` |
| `plugin :otp_rails` (puma) | `plugin :odoshi` |
| socket default `tmp/otp-rails.sock` | `tmp/odoshi.sock` |

The Elixir sidecar mirrors the env and telemetry names. Old versions remain published
under `otp-rails` (0.2.1 is a pointer release); no compatibility shims — rename atomically.

Also in this release:
- Telemetry subscribers are isolated — one raising subscriber can't break the bus or
  reach the supervisor loop (QA round 2).

## v0.2.0 — 2026-09-13

**Puma plugin (DESIGN §4.2 step 2)** — `plugin :otp_rails` in `config/puma.rb`: the master
heartbeats worker-level state over the §5 socket; a missing worker reports `"degraded"`
(⇒ `child.degraded` telemetry, `meta: {workers, booted, phase}`) while puma replaces it —
visibility only, no lifecycle change. The `:puma` and `:solid_queue` adapters now export
`OTP_RAILS_CHILD_ID=<id>` to their children (explicit `env:` wins).

**Hardening from a three-track QA pass** (adversarial review + soak/stress + a Ruby⇄Elixir
contract harness now permanent in the sidecar's CI):
- Drain signals the whole process group — shell-wrapped cmds (`"a && b"`) no longer leave
  their real workload running after a "clean" shutdown, or duplicate it on restart (#24).
- Fan-out follows OTP: all affected children stop in reverse start order before any
  restart; declaration-order dependencies hold during `rest_for_one`/`one_for_all` (#14).
- One spawn path everywhere (fork → setsid → exec): an unspawnable `cmd:` is a child crash
  (exit 127 → strategy → escalation), not a supervisor crash; identical on macOS/Linux (#15).
- Socket hardening: 64 KiB line cap, string-typed `token`/`cmd`/`id`/`state`, unknown-id
  heartbeats dropped at intake, 64-connection cap, listen backlog 128, connection threads
  torn down on stop, unusable socket path ⇒ exit 78. A well-formed heartbeat naming a
  subtree id no longer crashes the tree (#25, #27, #16, #17, #30, #31).
- `stop` is prompt during stuck starts, restart fan-outs, and backoff sleeps — no more
  blowing platform grace periods (#28). One healthy interval resets the backoff ladder
  (#19). Non-restarted children leave no stale state or corpse telemetry (#20).
- `Heartbeat`: the beat thread survives raising/unencodable `state:`/`meta:` lambdas
  (falls back to last-good state / `{}`), and closes failed sockets — no fd growth while
  the supervisor is away (#26, #29).
- DESIGN §5 wire rules documented (token in the example, string fields, line cap, `ts`
  informational); the Elixir sidecar mirrors them byte-for-byte.

**Breaking:** `OtpRails::Heartbeat.start` returns the `Heartbeat` instance (so `#stop`
works) instead of the raw Thread; still `nil` when unsupervised (#23).

## v0.1.1 — 2026-09-12

- Gemspec only: author listed as `timimsms`. No code changes.

## v0.1.0 — 2026-09-12

First release: a slim, zero-runtime-dependency, OTP-style process supervisor for the
processes of a Rails app. The supervisor never loads Rails (DESIGN §9).

- **Supervision core** — `ChildSpec` with `permanent`/`transient`/`temporary` restart
  semantics; `one_for_one`, `rest_for_one`, `one_for_all` strategies; restart intensity
  with a sliding window that escalates (exit 70) when exceeded; `none`/`constant`/
  `exponential` backoff; generation-guarded exit handling (stale exits ignored).
- **Shutdown correctness** (#1) — `stop_all` drains in reverse start order, waiting per
  child (SIGTERM, then SIGKILL of the process group after `shutdown:`). Exit codes:
  0 clean, 70 escalation, 78 config error. Orphan prevention on Linux via
  `prctl(PR_SET_PDEATHSIG, SIGTERM)`; macOS has no equivalent (documented limitation).
- **Passive probes** (#2) — `probe: { tcp: PORT }` / `probe: { http: URL }` on `:command`:
  `:starting` until the probe answers, then `:healthy`. `start_timeout` exceeded ⇒ drain ⇒
  counts as a crash ⇒ strategy applies.
- **Periodic health loop** (#3) — per-child monitor at `health_interval` (default 5s);
  `:degraded` emits telemetry only; `degraded_restart_after: N` drains after N consecutive
  degraded reports (flows through the crash path, so intensity applies).
- **`:puma` adapter, beside mode** (#4) — wraps the puma master; health = HTTP `/up` probe;
  drain = SIGTERM (Puma graceful). `opts[:port]` or a literal `port NNNN` in the config.
- **Active heartbeat socket** (#5) — Unix socket (default `tmp/otp-rails.sock`, mode 0600),
  per-boot token via `OTP_RAILS_SOCK` / `OTP_RAILS_TOKEN`; NDJSON heartbeats
  `{"id","state","ts","token","meta"}`; bad token dropped; 3 missed intervals ⇒ `:degraded`,
  6 ⇒ `:dead` ⇒ restart; `{"cmd":"restart","id":...}` control messages. This wire protocol
  is the contract consumed by the Elixir sidecar (`shishi-odoshi/beam`).
- **`:solid_queue` adapter + heartbeat helper** (#6) — wraps `bin/jobs`; health = active
  heartbeat, not the DB table. `require "otp_rails/heartbeat"` is Rails-free and
  self-contained; silently a no-op when unsupervised.
- **Nested supervisors** (#7) — `supervisor :background do ... end` creates a subtree with
  its own strategy/intensity/backoff; subtree escalation is an ordinary child exit in the
  parent; restarted subtrees get a fresh intensity window.
