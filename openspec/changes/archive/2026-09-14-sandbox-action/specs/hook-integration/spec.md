# hook-integration Delta

## MODIFIED Requirements

### Requirement: Return Value Protocol
Hook functions SHALL return nil or a plist with keys from the set `:confirm`, `:block`, `:stop`, `:result`, `:args`, `:name`, as defined by gptel's `gptel-pre-tool-call-functions` documentation. A rule action returning `(:confirm nil :args NEWARGS)` SHALL cause gptel to merge NEWARGS into the executing tool-call object, the LLM-visible message history, and the confirmation UI display.

#### Scenario: Validation returns :block for unknown tool
- GIVEN a tool call names an unknown tool
- WHEN validation returns `(:block "...")`
- THEN the gptel FSM SHALL mark the tool call as errored
- AND send the block reason to the LLM as a `<tool_call_error>`.

#### Scenario: Security hook returns :confirm nil (auto-approve)
- GIVEN a rule matches with action `allow`
- WHEN the security hook returns `(:confirm nil)`
- THEN the gptel FSM SHALL store `:confirm nil` on the tool-call
- AND Layer 2 confirmation checks SHALL be skipped
- AND the tool SHALL execute without user prompt.

#### Scenario: Security hook returns :confirm t (force prompt)
- GIVEN a rule matches with action `ask`
- WHEN the security hook returns `(:confirm t)`
- THEN the gptel FSM SHALL store `:confirm t` on the tool-call
- AND the user SHALL be prompted regardless of the tool's `:confirm` slot.

#### Scenario: Security hook returns :args rewrite (sandbox)
- GIVEN a rule matches with action `sandbox`
- WHEN the security hook returns `(:confirm nil :args (:command "bwrap … make test"))`
- THEN the tool SHALL execute with the wrapped command
- AND the rewritten args SHALL be visible in the LLM history and confirm UI.

#### Scenario: Security hook returns nil (defer to tool's :confirm)
- GIVEN no rule matches
- WHEN the security hook returns nil
- THEN the gptel FSM SHALL fall through to the tool's `:confirm` slot
- AND if the tool's `:confirm` is t, the user SHALL be prompted
- AND if the tool's `:confirm` is nil (or absent), the tool SHALL auto-execute.
