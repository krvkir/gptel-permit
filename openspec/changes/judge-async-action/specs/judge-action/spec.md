# judge-action Delta

## ADDED Requirements

### Requirement: Judge action form
The rule engine SHALL support the action form `(judge . ACTION)` with
ACTION one of `allow` or `sandbox`. A rule carrying a judge action matches
when its conditions match, exactly like any other rule; its verdict is
produced by the judge: a SAFE verdict SHALL apply ACTION, and UNSAFE or any
failure class SHALL NOT apply ACTION. The judge is deny-only: it never
produces a block. A malformed action pair (e.g. `(judge . deny)`,
`(judge . ask)`) SHALL be rejected at rule-evaluation time with a logged
warning and the rule SHALL be treated as `ask` (fail-closed).

#### Scenario: SAFE applies the paired action
- GIVEN a rule `(:tool "Bash" :conditions ((:command . "^make ")) :action (judge . allow))`
  and a judge configured
- WHEN a Bash call `:command "make test"` is evaluated in sync mode and the
  judge answers SAFE
- THEN the hook returns `(:confirm nil)` — the call auto-runs.

#### Scenario: UNSAFE does not apply the action
- GIVEN the same rule in sync mode
- WHEN the judge answers UNSAFE
- THEN the rule scan continues from the next rule after the judge rule
- AND if no later rule matches, the call falls back to the normal
  confirmation path.

#### Scenario: Malformed pair fails closed
- GIVEN a rule with `:action (judge . deny)`
- WHEN the rule is evaluated
- THEN a warning is logged and the rule's effective action is `ask`.

### Requirement: Async judge resolution
When `gptel-permit-judge-async` is non-nil (default), the judge action SHALL
judge asynchronously: the hook SHALL fire a non-blocking `gptel-request`,
arm a watchdog timer at `gptel-permit-judge-timeout` seconds, and return
`(:confirm t)` immediately so the user interface never blocks on the judge.
The callback SHALL resolve the pending call: on SAFE it SHALL locate the
pending-confirmation overlay by tool-call identity and accept the call
(rewriting args through the sandbox adapter registry for
`(judge . sandbox)`); on UNSAFE, any failure class, or timeout it SHALL
leave the prompt for the human (fail-closed by inaction) and log the
outcome. A callback that finds the user has already resolved the prompt
SHALL no-op. Setting `gptel-permit-judge-async` to nil SHALL evaluate the
judge action synchronously with the blocking request path (identical
semantics, blocking UX).

#### Scenario: SAFE auto-accepts asynchronously
- GIVEN `gptel-permit-judge-async` is t and a `(judge . allow)` rule matches
  a single-call pack
- WHEN the hook runs
- THEN the prompt appears immediately (no blocking) and the judge request is
  in flight
- AND when the judge answers SAFE, the pending call is accepted
  programmatically and runs without user input.

#### Scenario: Sandbox judge rewrites before acceptance
- GIVEN a `(judge . sandbox)` rule matching a Bash call and the bwrap backend
- WHEN the async judge answers SAFE
- THEN the accepted call's `:command` is the bwrap-wrapped string (the
  unwrapped command never executes).

#### Scenario: Timeout leaves the prompt
- GIVEN an async judge request that receives no response within
  `gptel-permit-judge-timeout`
- WHEN the watchdog fires
- THEN the call remains on the prompt, a `timeout` failure is logged
- AND a late response is discarded as already-resolved.

#### Scenario: User race loses safely
- GIVEN an async judge in flight on a pending call
- WHEN the user accepts the prompt before the verdict arrives
- THEN the callback detects the resolved call and no-ops — the user's
  decision stands.

### Requirement: Pack acceptance gating
Async auto-acceptance SHALL be all-or-nothing at pack granularity: the
callback SHALL accept a pending pack only when every pending call in the
pack is judge-gated and carries a SAFE verdict; a pack containing any call
without a SAFE judge verdict (non-judged call, UNSAFE, or failure) SHALL
stay on the prompt. No call SHALL be auto-run unless the judge (or the
user) approved exactly that call.

#### Scenario: Mixed pack never auto-accepts
- GIVEN a pack with one judge-gated call and one plain ask call
- WHEN the judge answers SAFE for the first
- THEN the pack stays on the prompt — the non-judged call is not auto-run.

#### Scenario: All-SAFE pack auto-accepts
- GIVEN a pack where both calls are judge-gated
- WHEN both judge callbacks report SAFE
- THEN the whole pack is accepted once, programmatically.
