## Context

The divider contract (from `judge-divider-parse`) parses the first
standalone SAFE/UNSAFE line and fails closed on ambiguity. Live
forensics on the unparseable log entries of 2026-09-21 showed:

- One response contained, on a single line, the prose answer
  sentence, a closing think tag, and the verdict word glued
  together — no standalone verdict line, so the divider correctly
  rejected it.
- Two other responses from the same cloud model deliberated
  taglessly and glued the verdict into a prose line ("So this is
  SAFE.") — no tag to cut on.

The user observed that the same judge model answered cleanly before
thinking-suppression parameters were introduced and leaks reasoning
once they are present.

## Goals / Non-Goals

- Goals: make tagged reasoning leaks parseable; let users turn the
  request-side thinking control off entirely.
- Non-Goals: relaxing the standalone-line requirement for verdict
  words (a line *ending* in a verdict word would false-positive on
  deliberation prose like "could this be unsafe." — rejected);
  parsing responses with no trustworthy boundary; changing the
  conflict rule itself.

## Decisions

1. **The switch gates only derived parameters.**
   `gptel-permit-judge-control-thinking` (default `t`) stops the
   backend-type derivation. Explicit `gptel-permit-judge-request-params`
   remain verbatim: setting them is the user's own explicit attempt
   to control thinking, not an automatic one.

2. **Closing-tag truncation: LAST closing tag, unclosed means no
   cut.** `gptel-permit--judge-drop-thinking` drops everything up to
   and including the last closing tag via `split-string` on the tag
   regexp. Multiple blocks: the answer follows the last one. No
   closing tag anywhere: the response is returned whole — an
   unclosed block gives no trustworthy boundary, and guessing where
   reasoning ends would risk dropping the verdict.

3. **The heuristic applies before the divider; the conflict rule
   applies after it.** A standalone draft verdict inside a closed
   reasoning block is dropped with the block and no longer poisons
   parsing; drafts outside any closed block still conflict and fail
   closed.

4. **No literal tag bytes in source.** The closing-tag regexp is
   built from character classes; tests build tags at runtime from
   string fragments. The development toolchain has been observed to
   silently corrupt literal tag bytes written into files (a byte
   probe found zero literal tag bytes in files that had been written
   containing them), so fragment-construction makes the tests
   provably immune to that corruption.

## Risks / Trade-offs

- A closing tag appearing *after* the real verdict (e.g. a stray tag
  at the end of a response) drops the verdict too: parse-fail, ask.
  Fail-closed direction; accepted.
- The tag regexp matches only think/thinking closers; other reasoning
  markers (`</output>`, custom markers) are ordinary text.
