# llm-judge Delta

## ADDED Requirements

### Requirement: Judge schema verdicts
The judge SHALL enforce the JSON verdict contract at the transport
layer where supported: when active, judge requests SHALL carry the
verdict JSON schema (an object with a `verdict` string field
constrained to the enum ["SAFE", "UNSAFE"] and a `rationale` string
field) via gptel's `:schema` request keyword, which backends map to
their structured-output mechanisms (Ollama `format`, OpenAI
`response_format`, Gemini `responseSchema`). Activation SHALL be
controlled by `gptel-permit-judge-use-schema`: `t` requests the
schema unconditionally; `auto` (the default) requests it only for
known-enforcing combinations — Ollama backends whose judge model
carries no `:cloud` tag, OpenAI backends, and Gemini backends —
excluding Ollama cloud models (the bridge silently drops `format`)
and Anthropic backends (gptel implements theirs via tool-use
machinery); `nil` never requests it. Gating SHALL affect only the
request field: the prompt instruction and the dual-layer parsing
SHALL be identical in every mode. The judge SHALL log the effective
schema mode once per request.

#### Scenario: Local Ollama model gets schema enforcement
- GIVEN `gptel-permit-judge-use-schema` is `auto` and the judge
  backend is Ollama with a local model
- **WHEN** the judge issues its request
- **THEN** the request carries the verdict schema in Ollama's `format`
  field
- **AND** the model's response content is the verdict JSON object with
  the enum respected.

#### Scenario: Cloud-tagged Ollama model is skipped
- GIVEN `gptel-permit-judge-use-schema` is `auto` and the judge model
  is `glm-5.3-flash:cloud`
- **WHEN** the judge issues its request
- **THEN** the request carries no schema field (the cloud bridge drops
  `format`)
- **AND** the prompt still instructs the JSON object shape, with the
  text contract as the parser's fallback.

#### Scenario: Anthropic excluded from auto
- GIVEN `gptel-permit-judge-use-schema` is `auto` and the judge
  backend is Anthropic
- **WHEN** the judge issues its request
- **THEN** the request carries no schema (gptel's Anthropic schema
  support rides tool-use machinery and is unverified against the
  judge's non-tool request).

#### Scenario: Explicit t overrides the auto exclusions
- GIVEN `gptel-permit-judge-use-schema` is `t`
- **WHEN** the judge issues its request on any configured backend
- **THEN** the request carries the schema regardless of the auto
  exclusions.

#### Scenario: nil never sends the schema
- GIVEN `gptel-permit-judge-use-schema` is `nil`
- **WHEN** the judge issues its request
- **THEN** the request carries no schema field; the judge still runs
  the dual-layer parser with the text contract as fallback.

#### Scenario: Schema mode is logged
- **WHEN** the judge issues its request
- **THEN** the `gptel-permit-log` request line records the effective
  schema mode.

## MODIFIED Requirements

### Requirement: Judge verdict contract and rationale
The judge prompt SHALL instruct the model to respond with a JSON
object containing a `verdict` field whose value is "SAFE" or "UNSAFE"
and a short `rationale` string field. The parser SHALL be dual-layer:
it SHALL strip leaked reasoning blocks (`​` / `<thinking>`) and one
surrounding markdown code-fence pair, then first accept a response
that is a single JSON object with `verdict` exactly "SAFE" or "UNSAFE"
and a string `rationale` (a `verdict` value outside the enum is a
rejection, not a text-contract candidate); if the JSON layer fails,
it SHALL fall back to the text contract — the last line whose entire
trimmed text is exactly SAFE or UNSAFE, with the text after it as the
rationale, and unparseable when standalone SAFE and UNSAFE lines both
appear. A response satisfying neither layer SHALL be unparseable and
the condition SHALL return nil. The rationale (from the JSON field or
the text after the verdict line) SHALL be retained
(`gptel-permit--last-judge-rationale`) for audit consumers, and
SHALL be truncated via `gptel-permit--truncate-arg` when it is the
raw response of a parse-fail.

#### Scenario: JSON verdict parses
- **WHEN** the judge responds `{"verdict": "SAFE", "rationale": "Only
  writes inside the project"}`
- **THEN** the condition returns t and the rationale "Only writes
  inside the project" is available for analytics logging.

#### Scenario: Fenced JSON parses
- **WHEN** the judge responds with the verdict object wrapped in a
  markdown ```json code fence
- **THEN** the JSON layer accepts it after stripping the fence.

#### Scenario: Text contract remains the fallback
- **WHEN** the judge responds "SAFE\nOnly writes inside the project"
  (ignoring the JSON instruction)
- **THEN** the JSON layer fails and the text layer parses the verdict
  as `safe` with "Only writes inside the project" as the rationale.

#### Scenario: Verdict outside the enum is a rejection
- **WHEN** the judge responds `{"verdict": "MAYBE", "rationale": "…"}`
- **THEN** the parser returns nil; the object is not re-parsed by the
  text layer, and the condition returns nil (fail-closed).

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
  C-g, or returns a response that satisfies neither the JSON verdict
  contract nor the text contract (after stripping leaked reasoning
  blocks)
- **THEN** the function returns nil and the failure is logged via
  `gptel-permit--log`.
