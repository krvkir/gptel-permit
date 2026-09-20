# analytics Delta

## ADDED Requirements

### Requirement: Judge verdict events
The event schema SHALL include the `judge-verdict` event type. When a
judge action resolves asynchronously, the callback SHALL emit a
`judge-verdict` event carrying the verdict (including failure classes), the
rationale, and the judged argument value, correlated with the original
tool-call event's id. A programmatic judge auto-accept SHALL be recorded as
a `decision` event with the choice `auto-allow`, distinct from a user
`allow` decision. The `judge-verdict` event SHALL be emitted from the
verdict-owning buffer's context so per-call judge state
(`gptel-permit--last-judge-verdict`, `gptel-permit--last-judge-rationale`)
is current.

#### Scenario: Async SAFE chain
- GIVEN analytics enabled and an async `(judge . allow)` call judged SAFE
- WHEN the callback resolves and the pack auto-accepts
- THEN the file contains tool-call, rule-match, verdict, confirm,
  judge-verdict (verdict `safe`, with rationale) and decision (choice
  `auto-allow`) events sharing one id.

#### Scenario: Async UNSAFE stays manual
- GIVEN analytics enabled and an async judge call answered UNSAFE that the
  user later accepts manually
- THEN a judge-verdict event records `unsafe` and the user's subsequent
  decision event records `allow` with a wait time measured from the original
  confirm event.
