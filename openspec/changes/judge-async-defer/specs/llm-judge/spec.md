# llm-judge Delta

## MODIFIED Requirements

### Requirement: Async judge resolution
The system SHALL support an asynchronous judge mode, selected by
`gptel-permit-judge-async` (default `auto`): the interface SHALL never
block on the judge, and the resolution SHALL be applied by a callback when
the verdict arrives. Two asynchronous parking modes SHALL exist:

- `prompt` (the fallback, and the only mode on unpatched gptel): the hook
  returns `(:confirm t)`; the manual-confirmation prompt appears while
  judging; the callback applies a programmatic resolution only when every
  pending call of the prompted pack is judge-gated and all their
  resolutions are uniform — all accept-class (allow, or sandbox with
  arguments rewritten through the sandbox adapter registry) → the pack is
  accepted programmatically; all `deny` → the pack is rejected, each call
  receiving the judge-rationale reason and no manual prompt. Any other
  outcome (an `ask` resolution, a mixture, a non-judged call, a judge
  failure, or audit-sampled selection) leaves the pack on the prompt.
- `defer` (requires the patched gptel, feature-detected; see the
  `tool-call-defer` capability): the hook returns `(:defer t)`; the call
  parks invisibly — neither executed nor prompted — and the callback
  resolves the call individually through gptel's deferred-call resolver
  with the verdict→action mapping's resolution. `ask` and failure
  resolutions resolve to the manual-confirmation verdict, surfacing the
  prompt exactly at that point. Pack gating does not apply: each deferred
  call resolves on its own verdict while pack-mates prompt or run
  independently.

In every asynchronous mode the wait SHALL be bounded by
`gptel-permit-judge-timeout` (a watchdog resolves the pending call as a
failure), a callback finding the call already resolved (user race, abort,
buffer death) SHALL change nothing and log the discarded verdict, and
audit-sampled calls SHALL always resolve to the manual confirmation
whatever the verdict. The symbol `t` SHALL be accepted as `prompt` for
compatibility, and `nil` SHALL select synchronous evaluation: the same
verdict-to-resolution mapping computed inline with a blocking judge
request. `auto` SHALL resolve to `defer` when the patched gptel is
detected, else `prompt`, announced by a one-time log line.

#### Scenario: SAFE auto-accepts asynchronously (prompt mode)
- GIVEN `gptel-permit-judge-async` is `prompt` and a `judge` rule
  matching a single-call pack
- WHEN the hook runs
- THEN the prompt appears immediately (nothing blocks) and the judge
  request is in flight
- AND when the judge answers SAFE, the pack is accepted programmatically
  and runs without user input.

#### Scenario: SAFE resolves invisibly (defer mode)
- GIVEN `gptel-permit-judge-async` is `defer` and a `judge` rule
  matching a call
- WHEN the hook runs
- THEN the hook defers the call, no prompt appears, the interface stays
  responsive
- AND when the judge answers SAFE, the call executes without any prompt
  having been shown.

#### Scenario: UNSAFE deny rejects without a prompt (defer mode)
- GIVEN a `(judge sandbox deny)` rule matching a call in defer mode
- WHEN the judge answers UNSAFE
- THEN the call is resolved as rejected with a reason containing the
  judge's rationale — no prompt is ever shown for it.

#### Scenario: UNSAFE ask surfaces the prompt late (defer mode)
- GIVEN a `judge` rule matching a call in defer mode
- WHEN the judge answers UNSAFE
- THEN the call resolves to the manual-confirmation verdict and the
  prompt appears at that point — the user was never blocked while the
  judge thought.

#### Scenario: Timeout resolves to the prompt (defer mode)
- GIVEN a deferred judge call whose request receives no response within
  `gptel-permit-judge-timeout`
- WHEN the watchdog resolves the call
- THEN the call resolves to the manual-confirmation verdict, the prompt
  appears, the failure is logged
- AND a late verdict is discarded as already-resolved.

#### Scenario: Mixed pack never resolves programmatically (prompt mode)
- GIVEN a pack with one judge-gated call and one plain ask call
- WHEN the judge answers SAFE for the first
- THEN the pack stays on the prompt — the non-judged call is not
  auto-run and the judged call is not auto-rejected.

#### Scenario: User race wins
- GIVEN an async judge in flight (either mode) on a call
- WHEN the user resolves the prompt or aborts the request before the
  verdict arrives
- THEN the callback changes nothing — the user's decision stands and the
  stale verdict is logged as discarded.

#### Scenario: Mode auto-selection
- GIVEN gptel without the defer patch
- WHEN `gptel-permit-judge-async` is `auto`
- THEN the effective mode is `prompt`; with the patch it is `defer`; a
  one-time log line announces the effective mode.
