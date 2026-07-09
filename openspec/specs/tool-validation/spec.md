# Tool Validation Specification

## Purpose
Validate tool calls structurally before permission rules are evaluated: ensure the tool is known, required arguments are present, and provided argument names match the tool specification.

## Requirements

### Requirement: Unknown Tool Detection
When a tool call names a tool not known to gptel, the validation hook SHALL return `:block` with a descriptive error message for the LLM.

#### Scenario: Unknown tool blocked
- GIVEN a tool call with `:name "InventedTool"`
- AND `(gptel-get-tool "InventedTool")` returns nil
- WHEN the validation hook processes this tool call
- THEN it SHALL return `(:block "Unknown tool `InventedTool'")`
- AND the LLM SHALL receive the error message via the FSM's error handling.

#### Scenario: Known tool passes through
- GIVEN a tool call with `:name "Read"`
- AND `(gptel-get-tool "Read")` returns a valid tool spec
- WHEN the validation hook processes this tool call
- THEN it SHALL proceed to argument validation.

### Requirement: Missing Required Arguments
When a tool call omits a non-optional argument (value is nil or `:json-false`), the validation hook SHALL return `:block` with a structured error listing all missing arguments.

#### Scenario: Required argument missing
- GIVEN a tool has required args `:file_path` and optional args `:start_line`, `:end_line`
- AND a tool call has `:args (:start_line 10 :end_line 20)` — missing `:file_path`
- WHEN the validation hook processes this tool call
- THEN it SHALL detect that `:file_path` is missing
- AND return `(:block "<error message listing missing args>")`.

#### Scenario: All required arguments present
- GIVEN a tool has required args `:regex`, `:path`
- AND a tool call has `:args (:regex "foo" :path "/tmp")`
- WHEN the validation hook processes this tool call
- THEN it SHALL find no missing required args
- AND SHALL NOT block for missing args.

### Requirement: Unknown Argument Detection
When a tool call provides argument names not present in the tool spec, the validation hook SHALL return `:block` with a fuzzy "did you mean?" hint suggesting the closest matching spec argument name.

#### Scenario: Typo in argument name
- GIVEN a tool has spec arg names `file_path`, `start_line`, `end_line`
- AND a tool call has `:args (:file_paht "foo.txt" :start_line 1)`
- WHEN the validation hook processes this tool call
- THEN it SHALL detect that `file_paht` is not a valid arg name
- AND find that `file_path` is the closest match (edit distance ≤ 8, shared substring)
- AND include a hint `"You provided 'file_paht' — did you mean 'file_path'?"` in the `:block` error.

#### Scenario: Multiple typos detected
- GIVEN a tool call with two unknown args and one missing required arg
- WHEN the validation hook processes this tool call
- THEN the error message SHALL list all unknown args and all missing required args
- AND include hints for each unknown arg.

#### Scenario: All arguments valid
- GIVEN all provided arg names exist in the tool spec
- WHEN the validation hook processes this tool call
- THEN it SHALL find no unknown args
- AND SHALL NOT block for unknown args.

### Requirement: Validation Runs Before Permissions
The validation hook SHALL be registered on `gptel-pre-tool-call-functions` before the security/permissions hook, ensuring structural validation completes before value-based rule matching.

#### Scenario: Ordering in the hook list
- GIVEN `gptel-pre-tool-call-functions` is evaluated
- WHEN the hook runs
- THEN the validation function SHALL be called before the security function
- AND if validation returns `:block`, the security hook SHALL skip the tool call via the early-return guard.

### Requirement: Validation Logging
When `gptel-permit-log-enabled` is non-nil, the validation hook SHALL log each check (unknown tool, missing args, unknown args, pass).

#### Scenario: Logged validation failure
- GIVEN `gptel-permit-log-enabled` is t
- AND a tool call has an unknown argument
- WHEN the validation hook processes this tool call
- THEN the log SHALL contain the detected validation failure
- AND the error message sent to the LLM SHALL be recorded in the log.
