# rule-engine-hooks Delta

## ADDED Requirements

### Requirement: Matched scope and origin on the tool call
When a rule matches, the engine SHALL annotate the enriched tool call
with the scope that produced the match and with that rule's origin —
where the rule came from — from the moment of the match decision
onward. Observers on `gptel-permit-events-functions` SHALL therefore be
able to name the scope and the exact source (a store file, a notebook
heading, the session buffer, the Custom option) that authorized a call
at every remaining event of that call's chain (`:rule-match`,
`:verdict`, `:confirm`).

The annotations SHALL NOT change any event payload: `:rule-match`
remains the matched action symbol, `:verdict` remains
`(ACTION . VERDICT)`, `:tool-call` remains nil; consumers that inspect
only payloads SHALL be unaffected. When no rule matched, neither scope
nor origin SHALL be reported.

#### Scenario: Scope is observable at the match event
- GIVEN an observer recording (TYPE, ACTION, SCOPE) triples
- AND the first matching rule comes from the notebook scope
- WHEN a tool call is processed
- THEN the observer SHALL see `:rule-match` with the matched action and
  the scope `notebook`
- AND the following `:verdict` event's tool call SHALL report the same
  scope.

#### Scenario: Origin rides with the scope
- GIVEN an observer recording the tool call at each event
- AND the first matching rule comes from a subfolder store of the
  project scope
- WHEN a tool call is processed
- THEN the call SHALL carry the scope `project`
- AND the call SHALL carry an origin identifying that store file.

#### Scenario: No match reports no scope
- GIVEN an observer and no matching rule in any scope
- WHEN the call is processed
- THEN the `:rule-match` event SHALL carry a nil action
- AND the call SHALL report no matched scope and no origin.

#### Scenario: Payload shape is unchanged
- GIVEN an observer recording the raw payload of every event
- AND a matching allow rule in the project scope
- WHEN the call is processed
- THEN the `:rule-match` payload SHALL be the action symbol `allow`
- AND the `:tool-call` payload SHALL be nil
- AND the `:verdict` payload SHALL be `(allow . (:confirm nil))`.

## Implementation details

- The scope rides on the enriched tool call under the key `:rule-scope`,
  and the reader-attached origin (see the rule-engine "Rule origin
  introspection" requirement) under `:rule-origin`; both are set the
  moment the matcher decides a match, before the `:rule-match` event is
  emitted; because the same plist object flows through
  `gptel-permit--emit-event` to every observer, no hook signature or
  payload changes.
- `:rule-scope` is the scope symbol as named in
  `gptel-permit-rule-scopes`; `:rule-origin` is the rule's `:origin`
  plist (`:scope`, plus `:file`/`:heading` where meaningful), not a
  copy the engine invents.
- Write both annotations as rebinding —
  `(setq enriched (plist-put enriched :rule-scope scope))` and the same
  for `:rule-origin` — and keep the enriched call a fresh list, not a
  shared tail of a caller's plist (`plist-put` mutates in place; the
  current `--enrich-tool-call` `append` satisfies this, and it is the
  kind of detail that must not be "simplified" later).
- On no match both keys are absent (or nil).
- Consumers: the analytics module reads `:rule-scope` to fill its
  `scope` fields (it keeps reporting the coarse scope, not the origin);
  the log uses both; other observers may ignore unknown tool-call keys,
  and nothing else may depend on either key.
