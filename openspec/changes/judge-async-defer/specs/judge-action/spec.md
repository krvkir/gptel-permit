# judge-action Delta

## MODIFIED Requirements

### Requirement: Async judge resolution
The judge action SHALL judge asynchronously when `gptel-permit-judge-async`
selects an asynchronous mode: the hook SHALL fire a non-blocking
`gptel-request`, arm a watchdog timer at `gptel-permit-judge-timeout`
seconds, and return immediately so the user interface never blocks on the
judge. Two asynchronous parking modes SHALL exist:

- `prompt`: the hook returns `(:confirm t)`; the pending-confirmation UI
  appears while judging; the callback auto-accepts only when every pending
  call in the pack is judge-gated SAFE (all-or-nothing), rewriting args
  through the sandbox adapter registry for `(judge . sandbox)`; UNSAFE,
  failure, or timeout leaves the prompt for the human.
- `defer`: the hook returns `(:defer t)` (requires the patched gptel,
  feature-detected); the call parks invisibly — neither executed nor
  prompted — and the callback resolves it via `gptel--resolve-tool-call`:
  SAFE applies the paired action's verdict (with sandbox args rewriting),
  while UNSAFE or any failure class re-scans the rule list from the rule
  after the judge rule and resolves with the first match's verdict, or with
  an empty verdict when no later rule matches (gptel's own confirmation
  defaults decide). No prompt appears unless a matched rule or gptel's
  defaults ask for one.

The default value SHALL be `auto`: `defer` when the patched gptel is
detected, else `prompt`. The symbol `t` SHALL be accepted as `prompt` for
compatibility, and `nil` SHALL select synchronous evaluation with the
blocking request path. In every asynchronous mode the callback SHALL no-op
when the call was already resolved (user race, abort, buffer death) and
SHALL log the outcome of every resolution path.

#### Scenario: SAFE auto-accepts asynchronously (prompt mode)
- GIVEN `gptel-permit-judge-async` is `prompt` and a `(judge . allow)` rule
  matching a single-call pack
- WHEN the hook runs
- THEN the prompt appears immediately (no blocking) and the judge request is
  in flight
- AND when the judge answers SAFE, the pending call is accepted
  programmatically and runs without user input.

#### Scenario: SAFE resolves invisibly (defer mode)
- GIVEN `gptel-permit-judge-async` is `defer` and a `(judge . allow)` rule
  matching a call
- WHEN the hook runs
- THEN the hook returns `(:defer t)`, no prompt appears, the interface stays
  responsive
- AND when the judge answers SAFE, the call is resolved with
  `(:confirm nil)` and executes without any prompt having been shown.

#### Scenario: UNSAFE falls through to later rules (defer mode)
- GIVEN a `(judge . allow)` rule followed by an `ask` rule, both matching,
  in defer mode
- WHEN the judge answers UNSAFE
- THEN the resolver re-scans from the rule after the judge rule and applies
  the `ask` rule's verdict (`(:confirm t)`) — the prompt that appears asks
  for a call the judge declined.

#### Scenario: Sandbox judge rewrites before resolution (defer mode)
- GIVEN a `(judge . sandbox)` rule matching a Bash call and the bwrap backend
- WHEN the async judge answers SAFE in defer mode
- THEN the call is resolved with `:args` carrying the bwrap-wrapped command
  (the unwrapped command never executes).

#### Scenario: Timeout resolves via fall-through (defer mode)
- GIVEN a deferred judge call whose request receives no response within
  `gptel-permit-judge-timeout`
- WHEN the watchdog fires
- THEN the resolver applies the `timeout` failure class semantics (re-scan
  from the next rule or empty verdict), a `timeout` failure is logged
- AND a late response is discarded as already-resolved.

#### Scenario: User race loses safely
- GIVEN an async judge in flight (either mode) on a call
- WHEN the user resolves the prompt or aborts the request before the
  verdict arrives
- THEN the callback detects the resolved/aborted call and no-ops — the
  user's decision stands.

#### Scenario: Mode auto-selection
- GIVEN gptel without the defer patch
- WHEN `gptel-permit-judge-async` is `auto`
- THEN the effective mode is `prompt`; with the patch it is `defer`; a
  one-time log line announces the effective mode.
