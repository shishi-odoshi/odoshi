# Changelog

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
