# rule-engine Delta

## MODIFIED Requirements

### Requirement: Match Algorithm — First Match Wins
The rule engine SHALL evaluate rules in order: session-local rules (`gptel-permit-rules`) first, then global rules (`gptel-permit-global-rules`). The action of the /first/ rule where all conditions match SHALL be returned. No further rules SHALL be evaluated after a match.

One exception: a `(judge . ACTION)` action that does not resolve SAFE
(UNSAFE or any failure class) SHALL continue the scan from the next rule
after the judge rule — the judge rule matched but its action was not
applied, so later rules remain reachable. This exception SHALL apply to the
synchronous judge path; the asynchronous judge path parks the call on the
prompt instead (see the `judge-action` capability) and the human is the
fallback.

#### Scenario: Session rule overrides global rule
- GIVEN `gptel-permit-rules` contains `(:tool "Read" :conditions ((:file_path . "logs")) :action allow)`
- AND `gptel-permit-global-rules` contains `(:tool "Read" :conditions ((:file_path . "logs")) :action ask)`
- WHEN matching a Read tool call with `:file_path "logs/debug.txt"`
- THEN the session rule SHALL match first
- AND the returned action SHALL be `allow`
- AND the global rule SHALL NOT be evaluated.

#### Scenario: Judge fall-through continues the scan
- GIVEN a `(judge . allow)` rule followed by an `ask` rule, both matching a
  call, and the judge in sync mode
- WHEN the judge answers UNSAFE
- THEN the scan continues at the rule after the judge rule
- AND the `ask` rule's verdict is returned.

#### Scenario: No rule matches — fallback
- GIVEN no rule in session-local or global rules matches the tool call
- WHEN the engine evaluates all rules
- THEN the return value SHALL be nil
- AND the caller SHALL defer to Layer 2 (tool's `:confirm` slot).
