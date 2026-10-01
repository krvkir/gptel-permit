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
parser SHALL first apply the closing-tag heuristic: when the
response contains a closing reasoning tag (think/thinking variants,
case-insensitive), everything up to and including the LAST one SHALL
be dropped as leaked reasoning; a tag glued onto a prose line still
cuts there, and a response without a closing tag SHALL be left
whole. Then the divider contract SHALL apply to the remaining text:
the FIRST line whose entire trimmed text is exactly SAFE or UNSAFE
(case-insensitive) divides it — text above it is dropped as leaked
reasoning, text below it is the rationale (later standalone verdict
words stay in the rationale). Verdict words glued into longer lines
do not count. If standalone SAFE and UNSAFE lines both appear
anywhere in the remaining text (an exploratory draft disagreeing with
the conclusion), the response SHALL be treated as unparseable and
the condition SHALL return nil. Anything else is unparseable. The
rationale SHALL be retained (`gptel-permit--last-judge-rationale`)
for audit consumers, untruncated when it is the raw response of a
parse-fail.

#### Scenario: Rationale captured
- **WHEN** the judge responds "SAFE\nOnly writes inside the project"
- **THEN** the condition returns t and the rationale "Only writes
  inside the project" is available for analytics logging.

#### Scenario: Leaked deliberation does not hide the verdict
- **WHEN** a thinking model responds with lines of reasoning followed
  by a standalone "SAFE" line and a rationale
- **THEN** the verdict parses as `safe`: the reasoning above the
  divider is dropped and the text below it is the rationale.

#### Scenario: Closing tag glued before the verdict parses
- **WHEN** a cloud model responds with prose reasoning, then a line
  ending in a closing think tag immediately followed by a standalone
  "SAFE" line and a rationale
- **THEN** the text through the closing tag is dropped and the
  verdict parses as `safe`.

#### Scenario: Draft verdict inside a closed block resolves
- **WHEN** leaked reasoning closed by a think tag contains a
  standalone verdict word that differs from the conclusion
- **THEN** the draft is dropped with the reasoning and the conclusion
  verdict parses.

#### Scenario: Unclosed reasoning keeps its drafts conflicting
- **WHEN** reasoning without any closing tag contains a standalone
  verdict word that differs from a later standalone conclusion
- **THEN** the response is unparseable and the condition returns nil
  (no trustworthy boundary exists to cut on).

#### Scenario: Conflicting standalone verdicts are unparseable
- **WHEN** the remaining text contains a standalone "UNSAFE" line (an
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
The judge SHALL let users pin its request body:
`gptel-permit-judge-request-params` (plist) SHALL be let-bound as
`gptel--request-params` around the judge request, taking precedence
over derived defaults. The switch `gptel-permit-judge-control-thinking`
(default non-nil) SHALL gate the derivation: when it is non-nil and
`gptel-permit-judge-request-params` is nil, the judge SHALL derive
backend-appropriate thinking-off parameters from the judge backend
struct type — Anthropic `:thinking (:type "disabled")`, OpenAI
`:reasoning_effort "minimal"`, Gemini `:generationConfig
(:thinkingConfig (:thinkingBudget 0))`, Ollama `:think :json-false` —
or `(:think "low")` when the judge model's base name is a GPT-OSS
model, which ignores booleans and cannot fully disable its trace —
and SHALL derive nil (no injection) for unrecognized backends. When
the switch is nil, nothing SHALL be derived and the judge request
SHALL carry no thinking-related parameters at all; a non-nil
`gptel-permit-judge-request-params` is the user's own explicit
attempt and SHALL always be sent verbatim regardless of the switch.
The judge SHALL log the effective params once per request.

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

#### Scenario: Switch off sends no thinking control
- GIVEN `gptel-permit-judge-control-thinking` is nil and
  `gptel-permit-judge-request-params` is nil
- **WHEN** the judge issues its request
- **THEN** no thinking-related fields are sent and the log records
  the effective params as nil.

#### Scenario: Switch off keeps explicit user params
- GIVEN `gptel-permit-judge-control-thinking` is nil and
  `gptel-permit-judge-request-params` is `(:think t)`
- **WHEN** the judge issues its request
- **THEN** the request body carries `think` true.

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
behave as `ask`. The judge action SHALL judge the call's full argument
set — every argument of the normalized `:args` alist, formatted as in the
condition form's prompt construction — rather than any single
condition-selected value.

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
callback. gptel MAY fire the callback several times per request: a cons
`(reasoning . TEXT)` carries leaked reasoning and is followed by the real
answer, a string is the answer itself, `nil` is a terminal failure, and
`t` an empty success body. Both request modes SHALL treat only terminal
deliveries (strings, `nil`, `t`) as verdicts — an intermediate reasoning
cons SHALL be ignored while the wait continues, and `nil`/`t` SHALL record
the `request-fail` failure class. Every failure class (`request-fail`,
`timeout`, `parse-fail`) SHALL be distinguishable and recordable in the
asynchronous path exactly as in the synchronous path. The judge *condition*
form (`gptel-permit-judge-safe-p`) SHALL remain synchronous and unchanged.

#### Scenario: Async request does not block
- WHEN an async judge request is issued
- THEN Emacs stays fully responsive while the verdict is awaited.

#### Scenario: Async failure classes match sync
- WHEN an async judge response is unparseable, times out, or the request
  errors
- THEN the corresponding failure class is recorded and logged with the
  same lines as the synchronous mode.

#### Scenario: Reasoning delivery does not resolve
- WHEN gptel delivers a `(reasoning . TEXT)` cons to the async callback
  before the final string
- THEN nothing is resolved while the intermediate delivery is processed
- AND the final string resolves the call normally.

#### Scenario: Empty success body records request-fail
- WHEN gptel delivers `t` (or `nil`) as the terminal callback delivery
- THEN `request-fail` is recorded and the resolution is the manual
  confirmation.

### Requirement: Judging indicator
A displayed manual-confirmation prompt SHALL show a judging indicator while
an asynchronous judge verdict is pending; the indicator
SHALL be removed when the pack is resolved (programmatically or by the
user). The indicator SHALL NOT modify the prompt's tool-call contents.
Because the judge module runs no code on the user's manual paths, the
indicator's lifetime SHALL additionally be tied to gptel's own cleanup:
each indicator overlay SHALL be registered as a preview teardown handle
on its tool overlay, which gptel applies on accept, steer and reject.

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

#### Scenario: Indicator does not outlive a manual accept
- GIVEN the judging indicator displayed on a prompted pack
- WHEN the user accepts manually (gptel runs the preview teardown handles)
- THEN the indicator overlay is removed, with no code of the judge module
  involved.