# analytics Delta

## ADDED Requirements

### Requirement: Judge verdict events
The event schema SHALL include the `judge-verdict` event type. When a judge
action resolves a call (synchronously or asynchronously), a `judge-verdict`
event SHALL be emitted carrying the verdict (including the failure classes
`parse-fail`, `request-fail`, `timeout`), the rationale, the judged
argument value, and the judge latency in milliseconds, correlated with the
original tool-call event's id. Asynchronous verdicts SHALL be emitted from
the verdict-owning buffer's context so per-call judge state is current.

#### Scenario: Async SAFE chain
- GIVEN analytics enabled and an async `judge` call answered SAFE
- WHEN the callback resolves and the pack auto-accepts
- THEN the file contains tool-call, rule-match, verdict, confirm,
  judge-verdict (verdict `safe`, with rationale and latency) and decision
  (choice `auto-allow`) events sharing one id.

#### Scenario: Async UNSAFE stays manual
- GIVEN analytics enabled and an async judge call answered UNSAFE whose
  resolution is `ask`
- THEN a judge-verdict event records `unsafe`
- AND the user's later manual decision event records their choice with a
  wait time measured from the original confirm event.

### Requirement: Programmatic judge decisions
Programmatic judge resolutions SHALL be recorded as `decision` events with
choices distinct from user decisions: an auto-accepted pack SHALL record
`auto-allow` (not the user's `allow`) and an auto-rejected pack SHALL
record `deny`. Pending-confirmation entries SHALL be popped with the
pre-rewrite arguments when the resolution rewrites them (the sandbox
analytics requirement), so wait times correlate correctly.

#### Scenario: Auto-reject is distinguishable
- GIVEN analytics enabled and an async `(judge sandbox deny)` call
  answered UNSAFE
- WHEN the callback rejects the pack
- THEN the decision event's choice is `deny` and the judge-verdict event
  carries the rationale fed to the model.

### Requirement: Audit sampling of judge-gated calls
Audit sampling SHALL extend to judge-gated calls in every mode: when
sampling selects such a call, the judge SHALL still be evaluated and the
verdict recorded (an `audit` event plus the `judge-verdict` event), but
the resolution SHALL be the manual confirmation regardless of the verdict
— a sampled call SHALL never be programmatically accepted or rejected.
This measures judge false-positives and false-UNSAFE rates alike.

#### Scenario: Sampled SAFE does not auto-accept
- GIVEN analytics enabled, sample-rate 1.0, and an async `judge` call
  answered SAFE
- WHEN the resolution is computed
- THEN the pack stays on the prompt, audit and judge-verdict events are
  recorded
- AND the user's manual decision is captured as usual.

### Requirement: Judge action serialization
Event fields recording the matched rule's action SHALL serialize list-form
judge actions distinctly (e.g. `(judge sandbox deny)` as
`judge:sandbox/deny`), so rule-match and verdict events remain well-formed
for list actions.

#### Scenario: List action serializes
- GIVEN analytics enabled and a call matching a rule with
  `:action (judge sandbox deny)`
- WHEN the rule-match event is emitted
- THEN its action field is the string `judge:sandbox/deny`.
