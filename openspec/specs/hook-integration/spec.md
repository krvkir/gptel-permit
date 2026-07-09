# Hook Integration Specification

## Purpose
Define how gptel-permit integrates with the gptel tool-call pipeline: hook registration, return value semantics, keybinding, and the simplified Layer 2 contract (tools use boolean `:confirm` only, all logic lives in gptel-permit).

## Requirements

### Requirement: Hook Registration
gptel-permit SHALL register its two hook functions on `gptel-pre-tool-call-functions` at load time, in order: validation first, security/permissions second.

#### Scenario: Both hooks registered on load
- GIVEN `(require 'gptel-permit)` is evaluated
- WHEN load completes
- THEN `gptel-pre-tool-call-functions` SHALL contain `gptel-permit--validate-tool-args`
- AND `gptel-pre-tool-call-functions` SHALL contain `gptel-permit-pre-tool-security-hook`
- AND the validation function SHALL appear before the security function in the hook list.

### Requirement: Hook Input Plist
Both hook functions SHALL receive a plist with keys `:name`, `:args`, `:buffer`, `:backend`, `:model` as provided by gptel's `gptel--handle-pre-tool`.

#### Scenario: Hook receives correct input
- GIVEN a gptel FSM is processing a tool call for "Read" with `:args (:file_path "foo.txt")`
- WHEN `gptel-pre-tool-call-functions` fires
- THEN each hook function SHALL receive a plist containing `:name "Read"`, `:args (:file_path "foo.txt")`, and at minimum `:buffer`, `:backend`, `:model`.

### Requirement: Return Value Protocol
Hook functions SHALL return nil or a plist with keys from the set `:confirm`, `:block`, `:stop`, `:result`, `:args`, `:name`, as defined by gptel's `gptel-pre-tool-call-functions` documentation.

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

#### Scenario: Security hook returns nil (defer to Layer 2)
- GIVEN no rule matches
- WHEN the security hook returns nil
- THEN the gptel FSM SHALL fall through to the tool's `:confirm` slot
- AND if the tool's `:confirm` is t, the user SHALL be prompted
- AND if the tool's `:confirm` is nil, the tool SHALL auto-execute.

### Requirement: Keybinding
gptel-permit SHALL bind `C-c C-b` in `gptel-tool-call-actions-map` to `gptel-permit-confirm-or-add-rule`.

#### Scenario: Interactive rule creation via keybinding
- GIVEN a tool-call confirmation overlay is displayed to the user
- WHEN the user presses `C-c C-b`
- THEN `gptel-permit-confirm-or-add-rule` SHALL be invoked
- AND the user SHALL be prompted to select a tool call, argument, regexp, and action
- AND the new rule SHALL be added to `gptel-permit-rules`
- AND it SHALL be applied immediately to pending tool calls.

#### Scenario: Rule creation when called without prefix arg
- GIVEN the user invokes `gptel-permit-confirm-or-add-rule` (e.g., via `C-c C-b`)
- AND no prefix arg was given
- THEN the function SHALL NOT require a prefix arg to enter rule-creation mode
- AND SHALL proceed to prompt for tool/arg/regexp/action selection.

### Requirement: Simplified Layer 2 Contract
gptel-agent-tools.el SHALL define `:confirm` slots as boolean values only: `t` for tools that touch the filesystem, absent for others. No lambda functions, no `should-confirm-p`, no `should-confirm-write-p`, no `auto-confirm-writes`. All auto-confirm logic SHALL live in gptel-permit's rule engine.

#### Scenario: File-accessing tool has :confirm t
- GIVEN a tool like "Read" that accesses files
- WHEN defined via `gptel-make-tool`
- THEN its `:confirm` slot SHALL be `t`
- AND no lambda SHALL be present.

#### Scenario: Non-file tool has no :confirm
- GIVEN a tool like "Bash" that executes commands
- WHEN defined via `gptel-make-tool`
- THEN its `:confirm` slot SHALL be absent (or nil)
- AND the gptel FSM SHALL treat this as no confirmation by default.

#### Scenario: gptel-permit not installed — safe default
- GIVEN gptel-permit is not installed
- AND a file-accessing tool has `:confirm t`
- WHEN the LLM requests a tool call
- THEN the gptel FSM SHALL prompt the user for every file-accessing tool call
- AND this SHALL be the safe default behavior.

### Requirement: Protected Directories Defcustom
gptel-permit SHALL define `gptel-permit-protected-dirs` as a `defcustom` listing directories that trigger confirmation even for paths inside the project.

#### Scenario: Protected directory always prompts
- GIVEN `gptel-permit-protected-dirs` is `("~/.ssh/")`
- AND a tool call targets a path inside "~/.ssh/"
- AND `gptel-permit-global-rules` has no explicit allow rule for this path
- WHEN the rule engine evaluates the `:inside-protected-dirs` predicate in a deny or ask rule
- THEN the call SHALL either be denied or prompt the user
- AND SHALL NOT be auto-approved by a generic inside-project allow rule.
