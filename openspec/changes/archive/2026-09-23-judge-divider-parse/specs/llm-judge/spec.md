# llm-judge Delta

## MODIFIED Requirements

### Requirement: Judge verdict contract and rationale
The judge prompt SHALL instruct the model to answer with SAFE or
UNSAFE as the first line and one short rationale line after it. The
parser SHALL apply the divider contract: the FIRST line whose entire
trimmed text is exactly SAFE or UNSAFE (case-insensitive) divides the
response — text above it is dropped as leaked reasoning, text below
it is the rationale (later standalone verdict words stay in the
rationale). Verdict words glued into longer lines do not count. If
standalone SAFE and UNSAFE lines both appear anywhere in the response
(an exploratory draft disagreeing with the conclusion), the response
SHALL be treated as unparseable and the condition SHALL return nil.
Anything else is unparseable. No tag-based stripping SHALL occur;
reasoning markers are ordinary text above the divider. The rationale
SHALL be retained (`gptel-permit--last-judge-rationale`) for audit
consumers, untruncated when it is the raw response of a parse-fail.

#### Scenario: Rationale captured
- **WHEN** the judge responds "SAFE\nOnly writes inside the project"
- **THEN** the condition returns t and the rationale "Only writes
  inside the project" is available for analytics logging.

#### Scenario: Leaked deliberation does not hide the verdict
- **WHEN** a thinking model responds with lines of reasoning followed
  by a standalone "SAFE" line and a rationale
- **THEN** the verdict parses as `safe`: the reasoning above the
  divider is dropped and the text below it is the rationale.

#### Scenario: A draft verdict in leaked reasoning fail-closes
- **WHEN** leaked reasoning contains a standalone verdict word that
  differs from the conclusion (e.g. a draft "UNSAFE" line above a
  final standalone "SAFE" line, inside or outside any reasoning
  markers)
- **THEN** the response is unparseable and the condition returns nil.

#### Scenario: Conflicting standalone verdicts are unparseable
- **WHEN** the response contains a standalone "UNSAFE" line (an
  exploratory draft) and a later standalone "SAFE" line
- **THEN** the parser returns nil and the condition returns nil
  (fail-closed).

### Requirement: Judge condition callable
The system SHALL provide `gptel-permit-judge-safe-p`, a condition
function called as `(value tool-call)`, which returns non-nil only
when a configured judge model explicitly answers SAFE for the given
tool-call argument value. The judge SHALL be invoked synchronously
with a hard timeout and SHALL never itself produce a block verdict; a
negative, failed, or ambiguous judgement SHALL make the condition
return nil so the enclosing rule does not match.

#### Scenario: SAFE verdict matches
- **WHEN** `gptel-permit-judge-safe-p` is called for a Bash `:command`
  and the judge request returns a parseable SAFE verdict
- **THEN** the function returns t and stores the judge's rationale
  (the remainder of the response) in
  `gptel-permit--last-judge-rationale`.

#### Scenario: UNSAFE verdict does not match
- **WHEN** the judge request returns "UNSAFE"
- **THEN** the function returns nil and stores the rationale for
  audit.

#### Scenario: Judge unconfigured
- **WHEN** `gptel-permit-judge-backend` is nil
- **THEN** the function returns nil without making any request.

#### Scenario: Judge failure is fail-closed
- **WHEN** the judge request errors, times out, is interrupted with
  C-g, or returns text with no standalone SAFE or UNSAFE line
- **THEN** the function returns nil and the failure is logged via
  `gptel-permit--log`.

### Requirement: Judge failure observability
The judge SHALL distinguish failure classes from negative verdicts:
`gptel-permit--last-judge-verdict` SHALL hold one of `safe`, `unsafe`,
`parse-fail`, `request-fail`, or `timeout` (nil when no judge run
occurred), and `gptel-permit--last-judge-rationale` SHALL hold the
full raw judge response — kept untruncated to aid debugging — for the
failure class `parse-fail` (nil for `request-fail` and `timeout`).
Failure paths SHALL log explicit, distinguishable lines via
`gptel-permit--log`: request errors (`Judge request failed: …`),
timeouts (`Judge timeout after Ns`), C-g interruption (`Judge
interrupted`), and unparseable responses (`Judge response
unparseable: <full raw response>`). Fail-closed semantics are
unchanged: every failure class makes `gptel-permit-judge-safe-p`
return nil.

#### Scenario: Unparseable response is logged with raw text
- **WHEN** the judge backend responds `Sure, let me think about
  this…` (no standalone SAFE or UNSAFE line)
- **THEN** `gptel-permit--judge-parse-verdict` returns nil
- **AND** the log contains `Judge response unparseable: ` followed by
  the full response text
- **AND** `gptel-permit--last-judge-verdict` is `parse-fail` with the
  full raw response in `gptel-permit--last-judge-rationale`
- **AND** the condition returns nil.

#### Scenario: Timeout is logged as its own failure class
- **WHEN** `gptel-permit-judge-timeout` elapses with no response
- **THEN** the log contains `Judge timeout after Ns` (N = the timeout)
- **AND** `gptel-permit--last-judge-verdict` is `timeout`
- **AND** the condition returns nil.

#### Scenario: Request failure is recorded distinctly
- **WHEN** the judge request signals an error (bad backend name, HTTP
  failure)
- **THEN** the log contains `Judge request failed: ` with the error
  message
- **AND** `gptel-permit--last-judge-verdict` is `request-fail`
- **AND** the condition returns nil.

#### Scenario: Analytics sees the failure class
- GIVEN analytics enabled and a judged call whose response is
  unparseable
- **WHEN** the verdict event is emitted
- **THEN** its `judge-verdict` field is the string `parse-fail`
  (analytics passes `gptel-permit--last-judge-verdict` through
  unchanged).
