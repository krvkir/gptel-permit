## MODIFIED Requirements

### Requirement: Nil Filepath Handling
When an argument with path semantics (belonging to the `path` arg-group) is explicitly `nil` or completely absent/missing from the tool call arguments list, any rule condition targeting it SHALL treat its value as `""` (empty string) for rule matching. This empty string SHALL be expanded via `expand-file-name`, resolving it to the current directory (`default-directory`).

#### Scenario: Nil path argument matches wildcards
- GIVEN a Glob tool call with `:path nil`
- AND a rule condition `(path . ".*")`
- WHEN the engine evaluates this condition
- THEN the value nil SHALL be treated as `""`
- AND expanded to the current `default-directory`
- AND matched against the condition, succeeding.

#### Scenario: Missing optional path argument matches project predicate
- GIVEN a Grep tool call where `:path` is omitted from the arguments list
- AND a rule condition `(path . :inside-project)`
- AND the current `default-directory` is inside the active project root
- WHEN the engine evaluates this condition
- THEN the missing `:path` argument SHALL be treated as `""`
- AND expanded to the current directory
- AND matched against the `:inside-project` predicate, succeeding.
