# llm-judge Delta

## ADDED Requirements

### Requirement: Judge action form
The rule engine SHALL support judge actions in the `:action` slot:
the symbol `judge`, or a list whose first element is `judge` followed by
one or two action symbols. `judge` SHALL be equivalent to
`(judge allow ask)` and `(judge A)` to `(judge A ask)`; the second action
of `(judge ON-SAFE ON-UNSAFE)` supplies the UNSAFE resolution. ON-SAFE and
ON-UNSAFE SHALL each be one of `allow`, `deny`, `ask`, `sandbox`. A rule
with a judge action SHALL match on its conditions exactly like any other
rule — the judge takes no part in matching, and a matched judge rule SHALL
own the call: no later rule is evaluated on its account. The judge
verdict SHALL determine the matched rule's resolution: SAFE SHALL apply
ON-SAFE and UNSAFE SHALL apply ON-UNSAFE; a judge evaluation failure
(timeout, unparseable or failed response) SHALL resolve to a manual
confirmation. A `deny` resolution SHALL carry a block reason that includes
the judge's rationale. A malformed judge form (wrong arity or unknown
action symbol) SHALL be reported with a logged warning and the rule SHALL
behave as `ask`.

#### Scenario: Bare judge accepts on SAFE
- GIVEN a rule `(:tool "Bash" :conditions ((:command . "^make ")) :action judge)`
  and a configured judge
- WHEN a Bash call `:command "make test"` is evaluated and the judge answers
  SAFE
- THEN the call is auto-accepted (the equivalent of `allow`).

#### Scenario: Bare judge asks on UNSAFE
- GIVEN the same rule
- WHEN the judge answers UNSAFE
- THEN the call is presented for manual confirmation — no later rule is
  consulted.

#### Scenario: Two-action form rejects on UNSAFE
- GIVEN a rule `:action (judge sandbox deny)` matching a Bash call
- WHEN the judge answers SAFE
- THEN the call is auto-accepted with its arguments rewritten for the
  sandbox
- AND WHEN the judge answers UNSAFE on another call
- THEN the call is rejected with a block reason containing the judge's
  rationale, without a manual prompt.

#### Scenario: Sandbox on UNSAFE confines the call
- GIVEN a rule `:action (judge allow sandbox)` matching a Bash call
- WHEN the judge answers UNSAFE
- THEN the call is auto-accepted but its arguments are rewritten for the
  sandbox (the judge's verdict selects the confinement, not a rejection).

#### Scenario: Judge failure asks
- GIVEN a judge-action rule whose request times out
- WHEN the resolution is computed
- THEN the call is presented for manual confirmation and the failure is
  logged — the ON-UNSAFE action is not applied to a failure.

#### Scenario: Malformed form fails closed
- GIVEN a rule with `:action (judge allow deny extra)`
- WHEN the rule is evaluated
- THEN a warning is logged and the rule behaves as `ask`.

### Requirement: Async judge resolution
The system SHALL support an asynchronous judge mode (selected by
`gptel-permit-judge-async`, non-nil by default): the interface SHALL never
block on the judge; the manual-confirmation prompt for the call SHALL be
shown immediately while the judge request is in flight, and the resolution
SHALL be applied by a callback when the verdict arrives. The callback
SHALL apply a programmatic resolution only when every pending call of the
prompted pack is judge-gated and all their resolutions are uniform: all
accept-class (allow, or sandbox with arguments rewritten through the
sandbox adapter registry) → the pack is accepted programmatically; all
`deny` → the pack is rejected, each call receiving the judge-rationale
reason and no manual prompt. Any other outcome — an `ask` resolution, a
mixture of resolutions, a non-judged call in the pack, a judge failure, or
selection by audit sampling — SHALL leave the pack on the prompt for the
human. The asynchronous wait SHALL be bounded by `gptel-permit-judge-timeout`
(a watchdog resolves the pending call as a failure). A callback finding
the prompt already resolved by the user, the buffer gone, or the call
already executed SHALL change nothing and log the discarded verdict.
Synchronous mode (`gptel-permit-judge-async` nil) SHALL evaluate the same
verdict-to-resolution mapping inline with a blocking judge request.

#### Scenario: SAFE auto-accepts asynchronously
- GIVEN async mode and a `judge` rule matching a single-call pack
- WHEN the hook runs
- THEN the prompt appears immediately (nothing blocks) and the judge
  request is in flight
- AND when the judge answers SAFE, the pack is accepted programmatically
  and runs without user input.

#### Scenario: UNSAFE-to-deny rejects the pack asynchronously
- GIVEN async mode and a `(judge sandbox deny)` rule matching the pack's
  only call
- WHEN the judge answers UNSAFE
- THEN the pack is rejected programmatically, the model receives the
  rationale-bearing reason, and no prompt remains.

#### Scenario: Timeout leaves the prompt
- GIVEN an async judge request that receives no response within
  `gptel-permit-judge-timeout`
- WHEN the watchdog resolves the call
- THEN the pack remains on the prompt, the failure is logged
- AND a late verdict is discarded as already-resolved.

#### Scenario: Mixed pack never resolves programmatically
- GIVEN a pack with one judge-gated call and one plain ask call
- WHEN the judge answers SAFE for the first
- THEN the pack stays on the prompt — the non-judged call is not
  auto-run and the judged call is not auto-rejected.

#### Scenario: User race wins
- GIVEN an async judge in flight on a prompted pack
- WHEN the user accepts the prompt before the verdict arrives
- THEN the callback changes nothing — the user's decision stands and the
  stale verdict is logged as discarded.

### Requirement: Async judge request mode
The judge SHALL support an asynchronous request mode for the action form:
requests SHALL be issued without blocking Emacs, reusing the same prompt
construction, request isolation, request-params injection, and verdict
parsing as the synchronous mode, and the verdict SHALL be delivered to a
callback. Every failure class (`request-fail`, `timeout`, `parse-fail`)
SHALL be distinguishable and recordable in the asynchronous path exactly
as in the synchronous path. The judge *condition* form
(`gptel-permit-judge-safe-p`) SHALL remain synchronous and unchanged.

#### Scenario: Async request does not block
- WHEN an async judge request is issued
- THEN Emacs stays fully responsive while the verdict is awaited.

#### Scenario: Async failure classes match sync
- WHEN an async judge response is unparseable, times out, or the request
  errors
- THEN the corresponding failure class is recorded and logged with the
  same lines as the synchronous mode.

### Requirement: Judging indicator
A displayed manual-confirmation prompt SHALL show a judging indicator while
an asynchronous judge verdict is pending; the indicator
SHALL be removed when the pack is resolved (programmatically or by the
user). The indicator SHALL NOT modify the prompt's tool-call contents.

#### Scenario: Indicator appears and is removed
- GIVEN async mode and a judge-gated call whose prompt is displayed
- WHEN the judge request is in flight
- THEN the prompt shows the judging indicator
- AND when the verdict lands and the pack is accepted, the indicator is
  gone.

#### Scenario: User answers while judging
- GIVEN the judging indicator displayed
- WHEN the user rejects the prompt before the verdict arrives
- THEN the indicator is removed with the prompt and the stale verdict is
  discarded.
