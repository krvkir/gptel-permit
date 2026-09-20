# llm-judge Delta

## ADDED Requirements

### Requirement: Async judge request mode
The judge SHALL support an asynchronous request mode: the request SHALL be
issued via `gptel-request` with a real callback (non-blocking), reusing the
same prompt construction, request isolation, request-params injection, and
verdict parsing as the synchronous mode. Every failure class
(`request-fail`, `timeout`, `parse-fail`) SHALL be recordable in the
asynchronous path exactly as in the synchronous path, and
`gptel-permit-judge-safe-p` (the condition form) SHALL remain synchronous
and unchanged. A watchdog timer SHALL bound the asynchronous wait at
`gptel-permit-judge-timeout` seconds, resolving the pending call as
`timeout` — the underlying gptel request is not aborted by the watchdog (a
stray late response is discarded by the resolved guard).

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
