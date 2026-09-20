# Tasks

## 1. Schema request plumbing (gptel-permit-judge.el)
- [ ] 1.1 Add `gptel-permit--judge-verdict-schema` defconst: plist
      object schema — `verdict` string with enum ["SAFE" "UNSAFE"],
      `rationale` string (gptel's `gptel--preprocess-schema` adds
      `additionalProperties: false` and `required` at request time).
- [ ] 1.2 Add defcustom `gptel-permit-judge-use-schema` — `auto`
      (default), `t`, `nil` — with a docstring covering the gating
      rules and the cloud-tag/Anthropic exclusions.
- [ ] 1.3 Add pure `gptel-permit--judge-schema-active-p`: resolve
      `auto` against the judge backend struct type (Ollama/OpenAI/
      Gemini = on) and the judge model name's `:cloud` tag (Ollama +
      cloud tag = off; Anthropic and unknown backends = off); `t`/`nil`
      resolve directly.
- [ ] 1.4 In `gptel-permit--judge-request-sync`: when the predicate
      is true, pass `:schema gptel-permit--judge-verdict-schema` to
      `gptel-request`; extend the request-params log line with the
      effective schema mode.
- [ ] 1.5 Prompt: replace the first-line SAFE/UNSAFE instruction with
      the JSON object shape instruction (all modes); keep the policy
      preamble and the rest of the prompt builder unchanged.

## 2. Dual-layer parser (gptel-permit-judge.el)
- [ ] 2.1 Add pure `gptel-permit--judge-parse-json-verdict`: strip
      reasoning blocks and one surrounding markdown fence, bind
      `json-object-type`, `json-read-from-string` the whole response;
      accept only `verdict` exactly "SAFE"/"UNSAFE" plus a string
      `rationale`; return `(VERDICT . rationale)` or nil.
- [ ] 2.2 Make `gptel-permit--judge-parse-verdict` try the JSON layer
      first and fall back to the existing text parser; neither layer
      → nil (parse-fail path unchanged: truncated raw response
      retained and logged).
- [ ] 2.3 Update docstrings (`--judge-parse-verdict`,
      `gptel-permit--last-judge-rationale`, request-sync) for the
      dual-layer contract; the rationale from the JSON field flows
      into the rationale variable unchanged.

## 3. Tests (tests/gptel-permit-judge-test.el)
- [ ] 3.1 Payload dry-run: mock Ollama backend, schema active —
      request data carries `:format` with the verdict schema (enum
      present); schema inactive — no `:format` key.
- [ ] 3.2 Gating table: `auto` — local Ollama on, `:cloud`-tagged
      Ollama off, OpenAI on, Gemini on, Anthropic off, unknown off;
      `t` and `nil` override everywhere.
- [ ] 3.3 Parser table: JSON happy path, fenced JSON, JSON after a
      leaked reasoning block, rationale string extraction, verdict
      outside the enum → nil (no text fallback), invalid JSON → text
      fallback (existing text tests cover the fallback layer), both
      layers fail → nil.
- [ ] 3.4 Request keyword test: `:schema` present in captured
      `gptel-request` keys iff the predicate is true (`plist-member`,
      like the `:system nil` test).

## 4. Documentation
- [ ] 4.1 README: structured-outputs section — support matrix (local
      Ollama: enforced; Ollama `:cloud`: dropped, `auto` skips it;
      OpenAI: `response_format`; Gemini: `responseSchema`; Anthropic:
      excluded from `auto` pending verification), dual-layer parser
      description, `gptel-permit-judge-use-schema` customization, and
      the request-params `:format` clobber warning.
- [ ] 4.2 Defcustom and variable docstrings updated for schema mode
      and the unified JSON prompt instruction.

## 5. Verification
- [ ] 5.1 `make test` green; byte-compile clean;
      `openspec validate judge-schema-verdict --strict` passes.
- [ ] 5.2 Manual live pass: local Ollama model — SAFE, UNSAFE, timeout
      (confirm `:format` in the request log line and clean JSON
      verdicts); cloud model — confirm `auto` skips the schema, the
      text fallback fires, and JSONL `judge-verdict` values are
      correct.
- [ ] 5.3 Anthropic investigation (out of scope to enable): with an
      Anthropic backend and `gptel-permit-judge-use-schema` `t`,
      document what gptel's tool-based schema mechanism does to the
      judge request/response, for a follow-up decision.
