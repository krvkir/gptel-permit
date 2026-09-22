# Proposal: judge-divider-parse

## Why
The leak-tolerant verdict parser shipped with judge-logging-thinking
does tag-regexp surgery (strip reasoning blocks) and then scans for
the last standalone SAFE/UNSAFE line. The live pass suggests
something simpler: leaked reasoning always precedes the model's
answer, so a single divider rule does the whole job — find the
verdict word, drop everything above it, keep everything below it. No
strip step, no last-vs-first heuristics. Separately, truncating the
raw response on parse-fail (30+30 chars via
`gptel-permit--truncate-arg`) hid exactly the text that explains
what the model actually said; the full response makes parse-fails
debuggable from the log alone.

## What Changes
- `gptel-permit--judge-parse-verdict` becomes a divider: the first
  line whose entire trimmed text is exactly SAFE or UNSAFE splits the
  response — text above it is dropped as leaked reasoning, text below
  it is the rationale. Conforming responses (verdict on the first
  line) parse identically to before.
- `gptel-permit--judge-strip-thinking` is deleted: no tag-aware
  stripping anywhere; reasoning markers are ordinary text above the
  divider.
- The conflict rule is kept (fail-closed): standalone SAFE and UNSAFE
  lines in the same response — an exploratory draft disagreeing with
  the conclusion — are unparseable. This is the only behavioral
  difference vs stripping: a standalone verdict word drafted inside
  leaked reasoning previously got stripped and could still parse; it
  now fail-closes the response.
- Parse-fail responses are stored and logged in full, untruncated, in
  `gptel-permit--last-judge-rationale` and `*gptel-permit-log*`.

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `llm-judge`: "Judge verdict contract and rationale" becomes the
  divider contract; "Judge failure observability" keeps the full raw
  response untruncated; the fail-closed scenario of "Judge condition
  callable" drops its stripping parenthetical.

## Impact
- Code: `gptel-permit-judge.el` (parser rewrite, strip function
  removal, untruncated parse-fail path, docstrings).
- Tests: `tests/gptel-permit-judge-test.el` (strip tests removed,
  divider/marker/conflict/untruncated tests added).
- Docs: README (parsing paragraph, unparseable log-line description).
- Ordering: archive this before `judge-schema-verdict`, whose delta
  describes the divider as its text fallback layer.
