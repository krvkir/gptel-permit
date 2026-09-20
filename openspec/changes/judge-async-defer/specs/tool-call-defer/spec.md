# tool-call-defer Delta

## ADDED Requirements

### Requirement: Deferred pre-tool verdicts
gptel's pre-tool hook protocol SHALL support deferred verdicts: a hook MAY
return `(:defer t)` for a tool call, and gptel SHALL then mark the call with
`(:defer t)` and apply no other hook verdict to it. Deferred calls SHALL be
excluded from `gptel--handle-tool-use`'s processing — they are neither
executed nor added to the pending-confirmation prompt — and the request's
final LLM round-trip SHALL be suppressed while any tool call remains
deferred (the remaining-call count includes deferred calls). The hook
invocation plist SHALL carry the request's `:fsm` so deferred verdicts can
be resolved later. This contract SHALL be feature-detectable (the resolver
function's presence).

#### Scenario: Deferred call neither runs nor prompts
- GIVEN a request with one Bash call whose pre-tool hook returns
  `(:defer t)`
- WHEN the FSM reaches the tool-use state
- THEN the call is not executed and no confirmation prompt contains it
- AND the request does not send its next round to the LLM while the call
  stays deferred.

### Requirement: Deferred call resolution
gptel SHALL provide `gptel--resolve-tool-call (fsm tool-call verdict)`,
which SHALL merge VERDICT into the tool-call through the same paths the
hook merge uses (`:confirm`, `:args`/`:name`, `:block`), clear the `:defer`
marker, and transition the FSM directly to the tool-use state (not
re-running pre-tool hooks, so hooks never observe rewritten arguments).
The resolved call SHALL then execute or prompt exactly as it would have
immediately after the original pre-tool pass. Resolving a call that is not
deferred, already has a result, or belongs to an aborted or finished
request SHALL be a no-op.

#### Scenario: SAFE-style resolution executes the call
- GIVEN a parked deferred call resolved with `(:confirm nil)`
- WHEN `gptel--resolve-tool-call` runs
- THEN the call executes in the next tool-use pass and its result
  transitions the request when all calls are complete.

#### Scenario: Resolving with :args rewrites the executed call
- GIVEN a deferred Bash call resolved with
  `(:confirm nil :args (:command WRAPPED))`
- WHEN the tool-use pass runs
- THEN the tool executes with WRAPPED as its command
- AND the prompt data sent to the LLM carries the rewritten arguments.

#### Scenario: No-op resolutions are inert
- GIVEN a deferred call whose request was aborted by the user
- WHEN the resolver is invoked
- THEN nothing happens — no execution, no prompt, no error.
