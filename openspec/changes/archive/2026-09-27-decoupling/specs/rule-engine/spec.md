# rule-engine Delta

## ADDED Requirements

### Requirement: Action dispatch registry
The rule engine SHALL resolve matched rule actions through a public alist
`gptel-permit-action-handlers` mapping action symbols to handler functions.
A handler SHALL be called with `(ID TOOL-CALL)` — the tool-call id and
the enriched tool call — and SHALL return a verdict plist per the gptel
hook protocol, or nil to defer.

The built-in actions SHALL be pre-registered with these verdicts:
- `allow` → `(:confirm nil)` (auto-approve),
- `deny` → `(:block "auto-denied")` (reject),
- `ask` → `(:confirm t)` (force prompt).

Optional modules SHALL register their own actions by adding entries to the
registry at module load time, idempotently; the core SHALL contain no
module-specific dispatch code.

When no rule matches, the engine SHALL return nil (defer), as before. When
a rule matches with an action that has no registered handler, the engine
SHALL fail closed with `(:confirm t)` and log the orphaned action. When a
handler itself returns nil, the engine SHALL defer exactly as for a
non-matching call.

#### Scenario: Custom action registered by a module
- GIVEN `gptel-permit-action-handlers` contains an entry mapping `my-action`
  to a handler returning `(:confirm nil)`
- AND a rule matching the call with `:action my-action`
- WHEN the engine processes the call
- THEN the handler SHALL be invoked with the call's id and enriched call
- AND the hook SHALL return `(:confirm nil)`.

#### Scenario: Unregistered action fails closed
- GIVEN a matching rule with `:action frobnicate`
- AND no `frobnicate` entry in `gptel-permit-action-handlers`
- AND the tool's own `:confirm` slot is nil
- WHEN the engine processes the call
- THEN the hook SHALL return `(:confirm t)` (it SHALL NOT defer, so the
  tool cannot auto-execute past an unresolved rule).

#### Scenario: Built-in action verdicts
- GIVEN matching rules with actions `allow`, `deny` and `ask`
- WHEN each is processed
- THEN the verdicts SHALL be `(:confirm nil)`, `(:block "auto-denied")`
  and `(:confirm t)` respectively, produced by the registered built-in
  handlers, not by dispatch special cases.

#### Scenario: Handler deferral
- GIVEN a registered handler that returns nil for some calls
- WHEN such a call matches its rule
- THEN the engine SHALL return nil and gptel's `:confirm` fallthrough
  SHALL apply.
