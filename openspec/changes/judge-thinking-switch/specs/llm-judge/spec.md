# llm-judge Delta

## MODIFIED Requirements

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
