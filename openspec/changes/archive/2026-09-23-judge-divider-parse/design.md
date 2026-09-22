# Design: judge-divider-parse

## Context
Shipped parser (judge-logging-thinking): strip thinking blocks
(tag regexps), take the last standalone SAFE/UNSAFE line, reject
mixed standalone verdicts. The user asked for the simpler divider
after the live pass, and for untruncated parse-fail logging —
truncation hinders debugging.

## Goals / Non-Goals

**Goals:**
- One parse rule, no regexps, no tag awareness.
- Full-debuggability logs on parse-fail.
- Fail-closed semantics preserved; conforming responses unchanged.

**Non-Goals:**
- JSON verdicts (separate change: judge-schema-verdict).
- Prompt, timeout, failure-class, or analytics changes.

## Decisions

1. **Divider at the first standalone verdict line.** Leaked
   reasoning precedes answers, so the first line that is exactly
   SAFE or UNSAFE (upcased, trimmed) divides thinking (dropped) from
   rationale (kept). Line-exact matching stays, so "SAFETY" or
   mid-sentence verdict words never trigger; a verdict word glued
   into a longer line still does not count. Duplicate same-word
   lines below the divider remain part of the rationale.

2. **No tag stripping.** The strip function is deleted. Markers are
   invisible to the divider contract: any line above it is dropped
   regardless of content. Consequence: a standalone verdict word
   drafted inside leaked reasoning no longer disappears into the
   strip; it feeds the conflict rule and fail-closes the response.
   That is more conservative than before (previously stripped →
   could parse), never less.

3. **Conflict rule kept.** Standalone SAFE and UNSAFE lines both
   present anywhere → unparseable. Without it, a SAFE draft inside
   reasoning plus an UNSAFE conclusion would parse as safe off the
   first divider — an auto-allow against the model's conclusion.
   Fail-closed stays; the JSON schema change will make such
   responses structurally impossible on enforcing backends.

4. **Full raw response on parse-fail.** The 30+30 truncation bound
   hid the tail that explains the model. Store and log the response
   verbatim; JSONL analytics never truncated the rationale anyway
   and continues to pass it through.

## Risks / Trade-offs
- Draft conflicts parse-fail where stripping parsed before: more
  asks, never more allows.
- Longer log lines and JSONL entries on parse-fail: accepted, the
  debugging value outweighs the bytes.
