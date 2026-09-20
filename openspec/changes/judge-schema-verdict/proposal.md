# Proposal: judge-schema-verdict

## Why
The judge's verdict contract is its most fragile part because it is
lexical: verdicts are parsed out of free text, so every model quirk
becomes a parser bug. The `judge-logging-thinking` live pass needed
three parser extensions in one evening (reasoning-block stripping,
last-standalone-line matching, conflict rejection) and still documents
a hard limitation — a verdict word glued mid-line is unparseable.
Structured outputs remove the problem class in the transport: with an
enforced JSON schema the model cannot emit anything but the verdict
object. This is verified working on this machine — `qwen3.5:4b` under
an Ollama `format` schema answered exactly
`{"verdict": "SAFE", "rationale": "…"}` — grammar-constrained, enum
respected.

gptel already plumbs this end to end: `gptel-request` accepts a
`:schema` keyword, and each built-in backend consumes it (Ollama
`format`, OpenAI `response_format`, Gemini `responseSchema`). But
enforcement is not universal: Ollama's cloud bridge silently drops
`format` (verified — `glm-5.3-flash:cloud` deliberated in prose
despite a full schema and `think: false`; Ollama's docs state cloud
models do not support structured outputs), and gptel implements
Anthropic's schema support via tool-use mechanics that interleave with
the tool-call FSM. So the text parser stays — as an automatic
fallback. The floor is today's behavior on every backend; the ceiling
is a verdict that cannot fail to parse.

## What Changes
- Judge requests carry a verdict JSON schema — an object with a
  `verdict` string field constrained to the enum ["SAFE", "UNSAFE"]
  and a short `rationale` string field — via gptel's `:schema`
  keyword when schema mode is active (gptel's preprocessing adds
  `additionalProperties: false` and `required` automatically).
- New defcustom `gptel-permit-judge-use-schema` (`auto` default, `t`,
  `nil`). `auto` requests the schema only for known-enforcing
  combinations: Ollama backends whose judge model carries no `:cloud`
  tag, OpenAI, and Gemini. `t` requests it unconditionally (escape
  hatch for future support); `nil` never requests it.
- Parsing becomes dual-layer and mode-independent: strip leaked
  reasoning blocks and markdown fences, try the JSON object, fall
  back to the existing text contract (last standalone SAFE/UNSAFE
  line); a response satisfying neither is a parse-fail. Fail-closed
  semantics are unchanged everywhere.
- The prompt's response-format instruction becomes the JSON object
  shape in all modes — Ollama's structured-outputs guide recommends
  describing the shape in the prompt even when enforcing, and for
  unenforcing bridges the prompt is the only constraint.
- Analytics and JSONL are untouched: the verdict symbols
  (`safe`/`unsafe`/`parse-fail`/`request-fail`/`timeout`) and
  rationale retention are identical in both layers.
- README gains a structured-outputs section with a per-backend support
  matrix and the cloud caveat.

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `llm-judge`: new "Judge schema verdicts" requirement (transport
  enforcement, gating, mode logging); the "Judge verdict contract and
  rationale" requirement becomes JSON-first with the text contract as
  the fallback layer; the fail-closed scenario under "Judge condition
  callable" is reworded for the dual-layer parser. Fail-closed
  semantics and the failure-class symbols are unchanged.

## Impact
- Code: `gptel-permit-judge.el` (schema constant, gating predicate,
  `:schema` pass-through in the request, JSON parse layer, prompt
  instruction, new defcustom, docstrings).
- Tests: `tests/gptel-permit-judge-test.el` (payload dry-run with
  `:format`, gating table, dual-layer parser table, request keyword
  test); existing text-parser tests keep passing as the fallback
  layer.
- Docs: README (structured outputs section, support matrix, cloud
  caveat, request-params `:format` clobber warning).
- No analytics code change (verdict/rationale shapes unchanged); rule
  engine, hook pipeline, and sandbox untouched.
- Dependencies: builds on the archived `judge-logging-thinking`
  baseline; requires gptel's `:schema` request keyword (present in the
  installed gptel).
