# llm-judge Delta

## ADDED Requirements

### Requirement: Judge failure observability
The judge SHALL distinguish failure classes from negative verdicts:
`gptel-permit--last-judge-verdict` SHALL hold one of `safe`, `unsafe`,
`parse-fail`, `request-fail`, or `timeout` (nil when no judge run occurred),
and `gptel-permit--last-judge-rationale` SHALL hold the truncated raw judge
response for the failure classes. Failure paths SHALL log explicit,
distinguishable lines via `gptel-permit--log`: request errors
(`Judge request failed: …`), timeouts (`Judge timeout after Ns`),
C-g interruption (`Judge interrupted`), and unparseable responses
(`Judge response unparseable: <truncated raw>`). Fail-closed semantics are
unchanged: every failure class makes `gptel-permit-judge-safe-p` return nil.

#### Scenario: Unparseable response is logged with raw text
- **WHEN** the judge backend responds `Sure, let me think about this…` (first
  line is neither SAFE nor UNSAFE)
- **THEN** `gptel-permit--judge-parse-verdict` returns nil
- **AND** the log contains `Judge response unparseable: ` followed by the
  truncated response text
- **AND** `gptel-permit--last-judge-verdict` is `parse-fail` with the truncated
  raw response in `gptel-permit--last-judge-rationale`
- **AND** the condition returns nil.

#### Scenario: Timeout is logged as its own failure class
- **WHEN** `gptel-permit-judge-timeout` elapses with no response
- **THEN** the log contains `Judge timeout after Ns` (N = the timeout)
- **AND** `gptel-permit--last-judge-verdict` is `timeout`
- **AND** the condition returns nil.

#### Scenario: Request failure is recorded distinctly
- **WHEN** the judge request signals an error (bad backend name, HTTP failure)
- **THEN** the log contains `Judge request failed: ` with the error message
- **AND** `gptel-permit--last-judge-verdict` is `request-fail`
- **AND** the condition returns nil.

#### Scenario: Analytics sees the failure class
- GIVEN analytics enabled and a judged call whose response is unparseable
- **WHEN** the verdict event is emitted
- **THEN** its `judge-verdict` field is the string `parse-fail` (analytics
  passes `gptel-permit--last-judge-verdict` through unchanged).

### Requirement: Judge request tuning
The judge SHALL let users pin its request body: `gptel-permit-judge-request-params`
(plist) SHALL be let-bound as `gptel--request-params` around the judge request,
taking precedence over derived defaults. When nil, the judge SHALL derive
backend-appropriate thinking-off parameters from the judge backend struct
type — Anthropic `:thinking (:type "disabled")`, OpenAI `:reasoning_effort
"minimal"`, Gemini `:generationConfig (:thinkingConfig (:thinkingBudget 0))`,
Ollama `:think :json-false` — and SHALL derive nil (no injection) for
unrecognized backends. The judge SHALL log the effective params once per
request. A non-nil `gptel-permit-judge-request-params` SHALL win over derived
values; an explicitly empty list disables injection entirely.

#### Scenario: User params are passed through
- GIVEN `gptel-permit-judge-request-params` is `(:reasoning_effort "low")` and
the judge backend is an OpenAI backend
- **WHEN** the judge issues its request
- **THEN** the request body carries `reasoning_effort "low"` regardless of the
derived default.

#### Scenario: Thinking disabled by default per backend
- GIVEN `gptel-permit-judge-request-params` is nil and the judge backend is an
Anthropic backend
- **WHEN** the judge issues its request
- **THEN** the request body carries `thinking` `("type" . "disabled")`
- **AND** the log records the derived params.

#### Scenario: Unknown backend gets no injection
- GIVEN `gptel-permit-judge-request-params` is nil and the judge backend is a
third-party backend
- **WHEN** the judge issues its request
- **THEN** no thinking-related fields are injected and nothing is derived.
