# llm-judge Delta

## ADDED Requirements

### Requirement: Judge per-call state lifecycle
The judge SHALL define its per-call state (`gptel-permit--last-judge-verdict`,
`gptel-permit--last-judge-rationale`) as buffer-local variables within the
`gptel-permit-judge` module, and SHALL register a reset function on
`gptel-permit-before-rule-match-functions` at load time. The reset SHALL run
once per processed tool call, before rule matching, so state set by a judged
call can never leak into a later, unjudged call's analytics events. The core
rule engine SHALL NOT declare, reference, or reset judge state itself.

#### Scenario: Stale verdict does not leak into an unjudged call
- GIVEN a buffer where call A ran the judge (verdict and rationale set)
- WHEN a later call B matches a rule whose conditions do not invoke the judge
- THEN call B's verdict event SHALL carry no judge fields, because the
  reset ran before call B's matching.

#### Scenario: Judge fields remain visible to the same call's verdict event
- GIVEN a call whose rule condition invokes the judge
- WHEN the judge answers SAFE with a rationale
- THEN the reset SHALL NOT run between matching and the verdict event, so
  the verdict event for that call SHALL carry `judge-verdict` and
  `judge-rationale`.
