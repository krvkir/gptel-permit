# analytics Delta

## ADDED Requirements

### Requirement: Decision correlation across arg rewrites
The decision event SHALL still correlate with the original confirm event when
a tool call's arguments are rewritten between the confirmation event
and the user (or programmatic) acceptance — e.g. interactive sandboxed
acceptance wrapping `:command` via `gptel-permit-accept-tool-calls-sandboxed`
(the pending-confirmation entry SHALL be popped with the pre-rewrite
arguments), so wait-time statistics remain correct. The rewrite itself
SHALL be recorded by carrying the wrapped arguments in the decision event's
tool-call payload, keeping the decision auditable against what actually ran.

#### Scenario: Sandbox hotkey decision correlates
- GIVEN analytics enabled and a pending Bash confirmation with args
  `(:command "make test")`
- WHEN the user accepts via `C-c C-s` and the sandboxed command runs
- THEN a decision event records `allow` with the correct wait-ms from the
  original confirm timestamp
- AND the decision event's payload carries the wrapped command string, not
  the original.
