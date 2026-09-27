# rule-engine-hooks Specification

## Purpose
The rule engine's extension surface: core-minted tool-call ids that need
no consumer coordination, a uniform callback signature for action handlers
and engine hooks, and the three engine hooks — per-call state lifecycle
(`gptel-permit-before-rule-match-functions`), event observation
(`gptel-permit-events-functions`), and verdict veto
(`gptel-permit-veto-functions`) — through which optional modules extend
the engine without the core containing any module-specific code.
## Requirements
### Requirement: Core-minted tool-call ids
The rule engine SHALL mint one tool-call id per processed pre-tool call,
unconditionally — including when no hook functions are registered. The id
SHALL be a string of the form `TIMESTAMP.PID.SERIAL` (local timestamp with
millisecond precision, the Emacs process id, a process-wide serial), unique
across sessions, across concurrent Emacs processes, and across calls within
a session, without coordination with any consumer. Minting SHALL NOT read
or depend on any analytics module state, including its log file.

#### Scenario: Ids are formatted and unique within a session
- GIVEN a session buffer in which two tool calls are processed
- WHEN both calls are evaluated by the security hook
- THEN each call's events SHALL carry one string id matching
  `^[0-9]\{8\}T[0-9]\{6\}\.[0-9]\{3\}\.[0-9]+\.[0-9]+$`, and the two
  calls' ids SHALL be distinct.

#### Scenario: Minting needs no consumers
- GIVEN `gptel-permit-events-functions`, `gptel-permit-veto-functions`
  and `gptel-permit-before-rule-match-functions` are all nil
- AND the analytics module is not loaded
- WHEN a matching allow rule is evaluated
- THEN the hook SHALL return `(:confirm nil)` exactly as with observers
  present, and no file or module state SHALL be touched.

### Requirement: Uniform engine callback signature
Every engine callback — action handlers and the functions on the three engine hooks — SHALL receive the tool-call ID as its first argument and the enriched TOOL-CALL as its second argument.
Callback-specific arguments follow. Any callback that needs neither
SHALL declare them with underscore names.

#### Scenario: Signature consistency probe
- GIVEN a probe function registered on each of the three engine hooks
  and a probe action handler registered in `gptel-permit-action-handlers`
- WHEN a matching tool call is processed
- THEN each probe SHALL have been called with the call's id in argument
  position 1 and the enriched tool-call plist in position 2.

### Requirement: Before-rule-match hook
`gptel-permit-before-rule-match-functions` SHALL be an abnormal hook run
exactly once per processed tool call, after the `:tool-call` event is
observed and before rule matching begins, called with
`(ID TOOL-CALL)`. Return values SHALL be ignored. Errors from hook
functions SHALL NOT be caught at the hook site: they SHALL propagate into
the security hook's fail-closed error handling (`(:confirm t)`).

#### Scenario: State prepared before matching
- GIVEN a module function on the hook that clears a buffer-local variable
- AND a rule whose condition populates that same variable
- WHEN a tool call is processed twice, the first call populating it
- THEN at the start of the second call's rule matching the variable SHALL
  be nil (the hook ran before matching), and the second call's verdict
  event SHALL carry no trace of the first call's value.

#### Scenario: Erroring lifecycle function fails closed
- GIVEN a function on `gptel-permit-before-rule-match-functions` that
  signals an error
- WHEN a tool call is processed
- THEN the security hook SHALL return `(:confirm t)`.

### Requirement: Events hook
`gptel-permit-events-functions` SHALL be an abnormal hook observing the
engine's events, called with `(ID TOOL-CALL TYPE PAYLOAD)` where TYPE is
one of `:tool-call`, `:rule-match`, `:verdict` or `:confirm`, and PAYLOAD
is nil for `:tool-call` and `:confirm`, the matched action symbol (nil when
no rule matched) for `:rule-match`, and `(ACTION . VERDICT)` for
`:verdict`. The `:rule-match` event SHALL fire at the point the match
decision is made — inside the matcher on the first matching rule, or once
with nil action after all rules failed. Each observer function SHALL run
isolated in `condition-case`: an erroring observer SHALL be logged and
SHALL NOT alter the verdict nor prevent later observers from running.
Observer return values SHALL be ignored.

#### Scenario: Allow chain observed in order
- GIVEN an observer recording (TYPE PAYLOAD) pairs and a matching allow
  rule
- WHEN the call is processed
- THEN the observer SHALL have seen `:tool-call`, then `:rule-match` with
  `allow`, then `:verdict` with `(allow . (:confirm nil))`, and no
  `:confirm` event.

#### Scenario: Ask chain includes a confirm event
- GIVEN an observer and a matching ask rule
- WHEN the call is processed
- THEN the chain SHALL end with a `:verdict` event followed by a
  `:confirm` event for the same id.

#### Scenario: No-match chain observes defer without confirm
- GIVEN an observer and no matching rule
- WHEN the call is processed
- THEN the observer SHALL have seen `:rule-match` with nil action and a
  `:verdict` event whose action is nil, and no `:confirm`.

#### Scenario: Erroring observer is isolated
- GIVEN two observers, the first signalling an error
- WHEN a matching allow rule is processed
- THEN the verdict SHALL still be `(:confirm nil)` and the second observer
  SHALL have seen all events.

### Requirement: Extensible event set
The set of event types delivered on `gptel-permit-events-functions` SHALL
be open, not exhaustive: the engine MAY emit additional event types in
future versions, through the same hook, with the same
`(ID TOOL-CALL TYPE PAYLOAD)` signature and the same per-function error
isolation; the payload of a new type is defined when that type is added.
A new event type SHALL NOT change the meaning, payload or per-chain
position of the existing types. Observer functions SHALL treat an unknown
TYPE as data, not as an error.

#### Scenario: An unknown event type reaches observers unchanged
- GIVEN an observer recording every (TYPE PAYLOAD) pair it receives
- WHEN an event with a TYPE outside the current enumeration is emitted
  through the events hook (as a future engine version may)
- THEN the observer SHALL have recorded that pair without error
- AND the observer SHALL still receive the later events of the same
  call's chain.

### Requirement: Veto hook
`gptel-permit-veto-functions` SHALL be an abnormal hook run with
`run-hook-with-args-until-success` after a verdict is computed and before
it is returned, called with `(ID TOOL-CALL VERDICT)`, and only when a rule
matched (the action SHALL be non-nil). A non-nil return SHALL make the
engine — not the veto function — upgrade the verdict to `(:confirm t)`,
preserving any `:args` rewrite. Veto functions SHALL NOT return modified
verdicts; they inspect and veto. Errors from veto functions SHALL NOT be
caught at the hook site: they SHALL fail the call closed (`(:confirm t)`).

#### Scenario: Vetoed sandbox verdict keeps its rewrite
- GIVEN a veto function that always returns t
- AND a matched rule whose registered handler returns
  `(:confirm nil :args (:command "wrapped"))`
- WHEN the call is processed
- THEN the returned verdict SHALL be `(:confirm t :args (:command
  "wrapped"))` — forced confirmation of the *rewritten* call.

#### Scenario: First positive predicate wins
- GIVEN two veto functions, both recording their invocation, the first
  returning t
- WHEN a matched call is processed
- THEN the verdict SHALL be upgraded and the second function SHALL NOT
  have been invoked.

#### Scenario: Deferred calls are not vetoed
- GIVEN a veto function that always returns t
- AND no matching rule
- WHEN the call is processed
- THEN the veto function SHALL NOT have been invoked and the hook SHALL
  return nil (defer to the tool's `:confirm` fallthrough).

#### Scenario: Erroring veto function fails closed
- GIVEN a veto function that signals an error
- WHEN a matched allow call is processed
- THEN the security hook SHALL return `(:confirm t)`.
