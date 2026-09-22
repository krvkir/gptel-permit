# Design: judge-schema-verdict

## Context
The judge parses verdicts out of free text with the divider contract:
the first standalone SAFE/UNSAFE line splits leaked reasoning from
the rationale, and conflicting standalone verdicts are rejected
(`gptel-permit--judge-parse-verdict`; simplified in the
`judge-divider-parse` change). The live
pass on `glm-5.3-flash:cloud` showed the cost of a lexical contract —
a verdict word glued onto a rationale line is unparseable by design —
and every model quirk risks another parser bandage.

Structured outputs make the contract structural:

- gptel accepts `:schema` on `gptel-request`; `gptel--schema` is
  copied into the prompt buffer and `gptel--preprocess-schema`
  converts symbol types to strings and adds `additionalProperties:
  false` plus `required` for object properties.
- Backends: Ollama injects the schema into the top-level `format`
  field (grammar-constrained decoding), OpenAI into
  `response_format` with `json_schema`, Gemini into `responseSchema`
  (after filtering unsupported attributes), Anthropic prepends a tool
  spec built from the schema.
- Empirically on this machine (Ollama 0.32.14): `qwen3.5:4b` +
  `format` schema + `think: false` answered with exactly
  `{"verdict": "SAFE", "rationale": "…"}` — the enum is enforced by
  the sampler and thinking stays out of content. The cloud model
  `glm-5.3-flash:cloud` with the same request: both `format` and
  `think` were silently dropped and the model deliberated in prose
  (Ollama documents cloud as not supporting structured outputs).

## Goals / Non-Goals

**Goals:**
- Make the verdict structurally parseable wherever the transport
  enforces it.
- Keep the text contract as an automatic fallback so no configuration
  behaves worse than today.
- Keep analytics, JSONL, failure classes, the policy preamble, and
  fail-closed semantics byte-identical.

**Non-Goals:**
- Asynchronous judging (separate changes).
- Anthropic schema support (tool-based in gptel; excluded from `auto`
  pending a verification pass).
- Changing the verdict symbol set, timeouts, retries, or the
  blast-radius preamble.

## Decisions

1. **Schema shape.** A plist defconstant:
   `(:type object :properties (:verdict (:type string :enum ["SAFE"
   "UNSAFE"]) :rationale (:type string)))`. The enum is the
   security-relevant part; enforced backends cannot sample any other
   verdict value. gptel's preprocessing supplies the strictness
   fields.

2. **Dual-layer parsing, JSON first, mode-independent.** The JSON
   layer strips one surrounding markdown code-fence pair, then reads
   the whole remaining response as JSON (bind `json-object-type`
   appropriately); accept only an object whose `verdict` is exactly
   "SAFE" or "UNSAFE" and whose `rationale` is a string. Client-side
   validation stays even under enforcement — enforcement is a backend
   property, not a guarantee. If the JSON layer fails, run the
   existing divider text parser (see `judge-divider-parse`) on the
   same response; prose-wrapped or partial JSON falls through to it.
   Neither layer succeeds → parse-fail (full raw response retained
   and logged, as today). A JSON object whose `verdict`
   is outside the enum is a *rejection* — the model hedged — not a
   text-fallback candidate.

3. **Gating: request field only.** `gptel-permit-judge-use-schema`
   controls only whether `:schema` rides the request. The prompt and
   the parser are identical in every mode: the JSON shape is always
   the instructed format and the text contract is always the
   fallback. This removes any mode-aware prompt bifurcation.
   - `auto` (default): request the schema only for known-enforcing
     combinations — Ollama without a `:cloud` model tag, OpenAI,
     Gemini. This mirrors the thinking-params derivation philosophy
     (derive only what is known): cloud-tagged Ollama models are
     provably dropped, Anthropic's mechanism is tool-based, unknown
     backends are unverified.
   - `t`: always request (escape hatch for future cloud/Anthropic
     support).
   - `nil`: never request (for a backend that chokes on the field).

4. **Prompt keeps the prose shape.** Ollama's structured-outputs guide
   recommends also passing the schema in the prompt; for unenforcing
   bridges it is the only constraint. The response-format instruction
   becomes the JSON object shape in all modes; the policy preamble is
   unchanged.

5. **Logging parity.** The request log line gains the effective schema
   mode alongside the request params, so live sessions can see what
   was sent.

6. **request-params interplay.** `gptel-permit-judge-request-params`
   still wins the merge; a user-pinned `:format` clobbers the schema's
   (documented user error in README). Derived thinking params are
   orthogonal — the local probe ran `think: false` and `format`
   together correctly.

7. **Analytics unchanged.** Both layers produce the same verdict
   symbols and rationale strings; `--judge-fields` passes them
   through verbatim, and JSONL needs no schema change.

## Risks / Trade-offs
- **Anthropic tool-loop interleave.** Excluded from `auto`; the
  verification task documents observed behavior for a possible
  follow-up. `t` remains the manual override.
- **Ollama cloud may gain support.** Docs and probes say dropped
  today; `t` is the documented escape hatch; `auto` tightens when
  Ollama ships it.
- **Sloppy JSON compliance on tiny models.** Mitigated by the text
  fallback layer; a prose-wrapped object that also lacks a standalone
  SAFE/UNSAFE line is a parse-fail (fail-closed), same as today.
