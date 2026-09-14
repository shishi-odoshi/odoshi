# CLAUDE.md — odoshi

You are building `odoshi`, a slim OTP-style process supervisor for Rails apps, under the
`shishi-odoshi` GitHub org. Read `docs/DESIGN.md` before any change; it is the source of truth.
`docs/PLAN.md` is the ordered backlog with acceptance criteria — work it top to bottom.

## Hard rules (from DESIGN §9 — do not relitigate)

1. **Nothing under `lib/odoshi/` may require Rails, ActiveSupport, ActiveRecord, or any gem.**
   The supervisor has zero runtime dependencies. If you think a dependency is needed, stop and
   write it up in `docs/PLAN.md` under "Open questions" instead of adding it.
2. The adapter interface is exactly `spawn / link / health / drain` (+ `kill` as last resort).
   Do not add methods to `Adapter`. New capabilities go in `opts`, not the interface.
3. Telemetry event names in `Telemetry::EVENTS` are a published contract for the Elixir sidecar.
   Adding an event requires a DESIGN §6 edit in the same PR. Never rename one.
4. The health socket protocol (DESIGN §5) is newline-delimited JSON. Keep it boring; no
   MessagePack, no length prefixes, no versions until there's a second consumer.
5. `config/supervisor.rb` is evaluated without Rails. Never reference `Rails.*` in the DSL.

## How to work

- Small PR-sized commits on a branch per PLAN item. Conventional commit prefixes
  (`feat:`, `fix:`, `test:`, `docs:`). Each commit leaves `rake test` green.
- Tests are Minitest, no mocking library. Process-level behavior is tested with real
  processes (`sleep`, `exit 1`, small Ruby scripts under `test/fixtures/`), never stubs —
  the whole point is that the supervisor works against real PIDs and signals.
- The kill tests in `test/supervisor_kill_test.rb` are the acceptance bar. If a change
  makes them flaky, fix the change, not the test. Timing constants live in one place.
- When you finish a PLAN item: tick it, note anything surprising under that item, commit.
- When you hit a genuine design fork not covered by DESIGN.md: do not guess. Add it to
  `docs/PLAN.md` "Open questions" with the options and your recommendation, and move to the
  next item that isn't blocked.
- Do not touch `docs/DESIGN.md` except the decision log, and only to *record* a decision Tim
  has made — never to make one.

## Repo map

```
exe/odoshi                 CLI: run | check | version
lib/odoshi/supervisor.rb   the loop: start, link, exit handling, strategy, intensity, backoff
lib/odoshi/adapter.rb      the 4-method interface + registry
lib/odoshi/adapters/       one file per adapter
lib/odoshi/dsl.rb          config/supervisor.rb loader
lib/odoshi/telemetry.rb    event bus + default subscribers
test/supervisor_kill_test.rb  chaos tests (real processes)
docs/DESIGN.md                frozen design; decision log at bottom
docs/PLAN.md                  ordered backlog with acceptance criteria
```

## Run

```
rake test                                    # all tests
ruby -Ilib -Itest test/supervisor_kill_test.rb
exe/odoshi check examples/supervisor.rb   # print a tree
exe/odoshi run examples/supervisor.rb     # supervise (Ctrl-C to stop)
```
