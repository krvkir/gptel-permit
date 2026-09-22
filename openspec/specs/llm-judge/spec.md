# llm-judge Specification

## Purpose
Synchronous LLM-as-a-judge support for grey-zone tool calls: the
`gptel-permit-judge-safe-p` rule condition asks a small model whether an
argument value is obviously safe, using a fixed blast-radius prompt
(plus optional user policy and history), a session-isolated request, and
a fail-closed SAFE/UNSAFE verdict contract with retained rationale and
distinguishable failure classes. The judge can never block; a negative,
failed, or ambiguous verdict simply makes the condition not match.
## Requirements
### Requirement: Judge condition callable
The system SHALL provide `gptel-permit-judge-safe-p`, a condition function
called as `(value tool-call)`, which returns non-nil only when a configured
judge model explicitly answers SAFE for the given tool-call argument value.
The judge SHALL be invoked synchronously with a hard timeout and SHALL never
itself produce a block verdict; a negative, failed, or ambiguous judgement
SHALL make the condition return nil so the enclosing rule does not match.

#### Scenario: SAFE verdict matches
- **WHEN** `gptel-permit-judge-safe-p` is called for a Bash `:command` and the
  judge request returns a parseable SAFE verdict
- **THEN** the function returns t and stores the judge's rationale (the
  remainder of the response) in `gptel-permit--last-judge-rationale`.

#### Scenario: UNSAFE verdict does not match
- **WHEN** the judge request returns "UNSAFE"
- **THEN** the function returns nil and stores the rationale for audit.

#### Scenario: Judge unconfigured
- **WHEN** `gptel-permit-judge-backend` is nil
- **THEN** the function returns nil without making any request.

#### Scenario: Judge failure is fail-closed
- **WHEN** the judge request errors, times out, is interrupted with
  C-g, or returns text with no standalone SAFE or UNSAFE line
- **THEN** the function returns nil and the failure is logged via
  `gptel-permit--log`.

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
`gptel-permit-judge-model`, with no system message (`:system nil`) so the
calling buffer's system prompt never reaches the judge, and SHALL NOT cause
the pre-tool-call hooks to run on the judge's own request.

#### Scenario: Judge request does not recurse into hooks
- **WHEN** the judge issues its gptel-request
- **THEN** `gptel-permit--apply-rules` is not invoked for the judge's
  internal request (bare requests lack the pre-tool FSM state).

#### Scenario: Session system prompt is not sent
- GIVEN the calling gptel buffer has a buffer-local `gptel-system-prompt`
- **WHEN** the judge issues its request
- **THEN** the request payload carries no system message; the judge preamble
  is the only role-setting text.

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
- **THEN** the log contains `Judge request failed: ` with the error message
- **AND** `gptel-permit--last-judge-verdict` is `request-fail`
- **AND** the condition returns nil.

#### Scenario: Analytics sees the failure class
- GIVEN analytics enabled and a judged call whose response is
  unparseable
- **WHEN** the verdict event is emitted
- **THEN** its `judge-verdict` field is the string `parse-fail`
  (analytics passes `gptel-permit--last-judge-verdict` through
  unchanged).

### Requirement: Judge request tuning
The judge SHALL let users pin its request body: `gptel-permit-judge-request-params`
(plist) SHALL be let-bound as `gptel--request-params` around the judge request,
taking precedence over derived defaults. When nil, the judge SHALL derive
backend-appropriate thinking-off parameters from the judge backend struct
type — Anthropic `:thinking (:type "disabled")`, OpenAI `:reasoning_effort
"minimal"`, Gemini `:generationConfig (:thinkingConfig (:thinkingBudget 0))`,
Ollama `:think :json-false` — or `(:think "low")` when the judge model's
base name is a GPT-OSS model, which ignores booleans and cannot fully
disable its trace — and SHALL derive nil (no injection) for
unrecognized backends. The judge SHALL log the effective params once per
request. A non-nil `gptel-permit-judge-request-params` SHALL win over derived
values; nil derives them (an empty plist is indistinguishable from nil in
Emacs Lisp).

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

#### Scenario: GPT-OSS judge model derives a thinking level
- GIVEN `gptel-permit-judge-request-params` is nil, the judge backend is an
Ollama backend and `gptel-permit-judge-model` is "gpt-oss:20b"
- **WHEN** the judge issues its request
- **THEN** the request body carries `think` `"low"` instead of a boolean
- **AND** the log records the derived params.

