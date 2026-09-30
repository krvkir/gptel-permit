# rule-engine Delta

## MODIFIED Requirements

### Requirement: Predicate Conditions
The system SHALL support built-in predicate keywords that are resolved at match time by calling functions with access to buffer context.

The built-in predicates SHALL include:
- `:inside-project` — true if the normalized path is inside the current project root or buffer file directory.
- `:outside-project` — true if the normalized path is outside the current project root / buffer file directory, or if neither can be resolved.
- `:inside-protected-dirs` — true if the normalized path is inside any directory listed in `gptel-permit-protected-dirs`.

Protected-dir entries beginning with `./` SHALL be resolved relative to the
project root (`gptel-permit--project-root`, falling back to
`default-directory`) via `gptel-permit--expand-protected-dir`; all other
entries SHALL be resolved with `expand-file-name`. The same resolution
SHALL be used by the sandbox's protected-path binding, so a single
`gptel-permit-protected-dirs` entry governs both rule matching and
sandboxing. The default value of `gptel-permit-protected-dirs` SHALL
include `./.git`.

When the predicate keyword does not match any built-in, the condition SHALL fail with a logged warning.

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

#### Scenario: inside-protected-dirs containment check
- GIVEN `gptel-permit-protected-dirs` is `("~/.ssh/" "~/.gnupg/")`
- AND a tool-call has `:path "/home/user/.ssh/config"`
- WHEN the predicate `:inside-protected-dirs` is resolved
- THEN `expand-file-name` resolves the path and each protected dir entry
- AND `file-in-directory-p` of the expanded path against "~/.ssh/" returns t
- AND the predicate SHALL return t.

#### Scenario: project-relative protected entry
- GIVEN `gptel-permit-protected-dirs` is `("./.git" "~/.ssh/")` and the
  project root is "/home/user/proj/"
- AND a tool-call has `:path "/home/user/proj/.git/hooks/pre-commit"`
- WHEN the predicate `:inside-protected-dirs` is resolved
- THEN "./.git" resolves to "/home/user/proj/.git"
- AND the predicate SHALL return t.
