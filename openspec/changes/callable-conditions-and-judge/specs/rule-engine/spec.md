# rule-engine Delta

## MODIFIED Requirements

### Requirement: Rule Structure
A rule SHALL be a plist with keys `:tool`, `:tool-group`, `:conditions`, and `:action`.

`:conditions` SHALL be an alist of `(TARGET . VALUE)` pairs where:
- TARGET is either a concrete arg keyword (e.g. `:file_path`) or the keyword `:arg-group`.
- VALUE is one of: a regexp string, a predicate keyword, or a function
  called as `(funcall VALUE arg-value tool-call)` whose non-nil return means
  the condition matches.

When `:tool` and `:tool-group` are both present in a rule, `:tool` SHALL take precedence and a warning SHALL be emitted.

When neither `:tool` nor `:tool-group` is present, the rule SHALL match any tool.

#### Scenario: Concrete tool rule with regexp condition
- GIVEN the rule `(:tool "Bash" :conditions ((:command . "^openspec [^&|;]*$")) :action allow)`
- WHEN matched against a Bash tool call with `:command "openspec foo"`
- THEN the rule SHALL match and return `allow`.

#### Scenario: Group-targeted rule with regexp condition
- GIVEN the rule `(:tool-group "read" :conditions ((:arg-group "path" . "secret")) :action deny)`
- AND a tool call for "Read" which belongs to the "read" tool-group
- AND the tool call has argument `:file_path` belonging to the "path" arg-group with value "/tmp/secret.txt"
- WHEN the rule engine evaluates this rule
- THEN it SHALL resolve "Read" → tool-group "read", `:file_path` → arg-group "path"
- AND test regexp "secret" against "/tmp/secret.txt" → match
- AND return `deny`.

#### Scenario: Callable condition matches
- GIVEN a rule `(:tool-group execute :conditions ((:command . my-safe-p)) :action sandbox)`
- AND `my-safe-p` is a function that returns t for read-only commands
- WHEN matched against a Bash tool call with `:command "ls"`
- THEN the engine SHALL call `my-safe-p` with the `:command` value and the
  tool-call plist, and the non-nil result SHALL make the condition match.

#### Scenario: Callable condition short-circuits
- GIVEN a rule with two conditions, the first a callable that returns nil,
  the second a callable
- WHEN the rule is evaluated
- THEN evaluation SHALL stop after the first nil condition
- AND the second callable SHALL NOT be invoked.

#### Scenario: Both :tool and :tool-group present
- GIVEN the rule `(:tool "Read" :tool-group "write" :conditions ((:file_path . "secret")) :action deny)`
- WHEN the rule engine evaluates this rule
- THEN it SHALL use `:tool "Read"`
- AND SHALL ignore `:tool-group "write"`
- AND SHALL emit a warning about the ambiguity.

#### Scenario: No tool or tool-group restriction
- GIVEN the rule `(:conditions ((:arg-group "path" . :inside-protected-dirs)) :action ask)`
- AND a tool call for "Read" (any tool) with a path in a protected directory
- WHEN the rule engine evaluates this rule
- THEN the absence of `:tool` and `:tool-group` SHALL mean "match any tool"
- AND the rule SHALL fire.

### Requirement: Predicate Conditions
The system SHALL support predicate keywords resolved at match time through
a lookup alist `gptel-permit--condition-predicates` mapping each keyword to a
named function called with `(value tool-call)`; the alist SHALL be user
extensible.

The built-in predicates SHALL include:
- `:inside-project` — true if the normalized path is inside the current project root or buffer file directory.
- `:outside-project` — true if the normalized path is outside the current project root / buffer file directory, or if neither can be resolved.
- `:inside-protected-dirs` — true if the normalized path is inside any directory listed in `gptel-permit-protected-dirs`.
- `:path-traversal` — true if the path contains `..` or is absolute.

When the predicate keyword does not match any entry, the condition SHALL fail with a logged warning.

#### Scenario: inside-project on a file in the project root
- GIVEN `default-directory` is "/home/user/myproject/"
- AND `(project-current)` returns a project with root "/home/user/myproject/"
- AND a tool-call has `:file_path "src/main.el"`
- WHEN the predicate `:inside-project` is resolved
- THEN `expand-file-name` resolves to "/home/user/myproject/src/main.el"
- AND `file-in-directory-p` against the project root returns t
- AND the predicate SHALL return t.

#### Scenario: outside-project when no project is active
- GIVEN `(project-current)` returns nil
- AND `(buffer-file-name)` returns nil
- AND a tool-call has `:file_path "/tmp/scratch.txt"`
- WHEN the predicate `:outside-project` is resolved
- THEN no base directory can be resolved
- AND the predicate SHALL return t (conservative: treat everything as outside).

#### Scenario: Custom predicate keyword registered
- GIVEN a user adds `(:inside-secrets . my-secrets-p)` to
  `gptel-permit--condition-predicates`
- WHEN a rule uses condition value `:inside-secrets`
- THEN the engine SHALL call `my-secrets-p` for the match.
