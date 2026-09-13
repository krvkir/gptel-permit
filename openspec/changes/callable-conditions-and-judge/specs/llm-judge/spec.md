# llm-judge Delta

## ADDED Requirements

### Requirement: Judge condition callable
The system SHALL provide `gptel-permit-judge-safe-p`, a condition function
called as `(value tool-call)`, which returns non-nil only when a configured
judge model explicitly answers SAFE for the given tool-call argument value.
The judge SHALL be invoked synchronously with a hard timeout and SHALL never
itself produce a block verdict; a negative, failed, or ambiguous judgement
SHALL make the condition return nil so the enclosing rule does not match.

#### Scenario: SAFE verdict matches
- **WHEN** `gptel-permit-judge-safe-p` is called for a Bash `:command` and the
  judge request returns "SAFE" as the first line
- **THEN** the function returns t and stores the judge's rationale (the
  remainder of the response) in `gptel-permit--last-judge-rationale`.

#### Scenario: UNSAFE verdict does not match
- **WHEN** the judge request returns "UNSAFE"
- **THEN** the function returns nil and stores the rationale for audit.

#### Scenario: Judge unconfigured
- **WHEN** `gptel-permit-judge-backend` is nil
- **THEN** the function returns nil without making any request.

#### Scenario: Judge failure is fail-closed
- **WHEN** the judge request errors, times out, is interrupted with C-g, or
  returns text whose first non-empty line is neither SAFE nor UNSAFE
- **THEN** the function returns nil and the failure is logged via
  `gptel-permit--log`.

### Requirement: Judge verdict contract and rationale
The judge prompt SHALL instruct the model to answer with SAFE or UNSAFE as
the first line and one short rationale line after it. The parser SHALL treat
anything else as UNSAFE. The rationale SHALL be retained
(`gptel-permit--last-judge-rationale`) for audit consumers.

#### Scenario: Rationale captured
- **WHEN** the judge responds "SAFE\nOnly writes inside the project"
- **THEN** the condition returns t and the rationale "Only writes inside the
  project" is available for analytics logging.

### Requirement: Judge context content
The judge SHALL receive: a fixed blast-radius policy preamble, the optional
user policy `gptel-permit-judge-policy` (default ""), the tool name, the
argument key being checked, and the truncated argument value. Session
history SHALL be included only when `gptel-permit-judge-history-entries`
is greater than 0, and then limited to that many most recent entries from
the tool call's buffer, each truncated.

#### Scenario: No history by default
- **WHEN** `gptel-permit-judge-history-entries` is 0 (default)
- **THEN** the judge prompt contains no conversation history, only the
  policy preamble, user policy, and the tool-call details.

#### Scenario: Opt-in history
- **WHEN** `gptel-permit-judge-history-entries` is 2
- **THEN** the judge prompt includes the last 2 user/assistant history
  entries from the tool call's `:buffer`, truncated.

### Requirement: Judge request isolation
The judge SHALL issue its request via `gptel-request` with tools, context,
and streaming disabled, using `gptel-permit-judge-backend` and
`gptel-permit-judge-model`, and SHALL NOT cause the pre-tool-call hooks to
run on the judge's own request.

#### Scenario: Judge request does not recurse into hooks
- **WHEN** the judge issues its gptel-request
- **THEN** `gptel-permit--apply-rules` is not invoked for the judge's
  internal request (bare requests lack the pre-tool FSM state).
