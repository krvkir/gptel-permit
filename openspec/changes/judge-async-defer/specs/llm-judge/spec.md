# llm-judge Delta

## MODIFIED Requirements

### Requirement: Async judge request mode
The judge SHALL support an asynchronous request mode: the request SHALL be
issued via `gptel-request` with a real callback (non-blocking), reusing the
same prompt construction, request isolation, request-params injection, and
verdict parsing as the synchronous mode. Every failure class
(`request-fail`, `timeout`, `parse-fail`) SHALL be recordable in the
asynchronous path exactly as in the synchronous path, and
`gptel-permit-judge-safe-p` (the condition form) SHALL remain synchronous
and unchanged. A watchdog timer SHALL bound the asynchronous wait at
`gptel-permit-judge-timeout` seconds; the watchdog resolves the pending call
through the active parking mode's resolution path (prompt mode leaves the
prompt; defer mode resolves via the resolver's fall-through semantics) and
a stray late response SHALL be discarded by the resolved guard. Verdict
events in asynchronous modes SHALL carry a `judge-latency-ms` field
(verdict arrival minus request issue).

#### Scenario: Async request does not block
- WHEN an async judge request is issued
- THEN Emacs remains responsive (no `accept-process-output` loop) and the
  verdict arrives on the callback thread.

#### Scenario: Async failure classes match sync
- WHEN an async judge response is unparseable, times out, or the request
  errors
- THEN the corresponding failure class (`parse-fail`, `timeout`,
  `request-fail`) is stored in `gptel-permit--last-judge-verdict` and logged
  with the same lines as the synchronous mode.

#### Scenario: Latency is measured
- GIVEN an async judge request issued at T0 with the verdict arriving at T1
- WHEN the judge-verdict event is emitted
- THEN it carries `judge-latency-ms` = (T1 − T0) in milliseconds.
