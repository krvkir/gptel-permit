# rule-engine Delta

## MODIFIED Requirements

### Requirement: Public helper names
The core's five module-facing helpers SHALL be public, spelled without
the `--` separator: `gptel-permit-log`, `gptel-permit-truncate-arg`,
`gptel-permit-project-root`, `gptel-permit-expand-protected-dir`,
`gptel-permit-emit-event`. The core shall contain no other module-facing
helper; symbols that remain `--`-prefixed are internal and no other
package may rely on them (tests excepted).

Renaming SHALL be a plain in-repo rename with no obsolete aliases: the
pre-split single package had no external dependents on these symbols.
The rules defcustom's `:type` widget and every affected docstring SHALL
use the new names.

#### Scenario: Rename is grep-clean
- GIVEN the whole repository
- WHEN grepped for `gptel-permit--\(log\|truncate-arg\|project-root\|expand-protected-dir\|emit-event\)`
- THEN no match SHALL be found in any `*.el` source, test, or docstring
  outside archived notes.

#### Scenario: Behavior invariance under rename
- GIVEN the full ERT suite with the renamed symbols
- WHEN it is run against the tree
- THEN every previously passing assertion SHALL pass with expectations
  unchanged except for renamed symbol names.

### Requirement: Core contains no module code
The core package SHALL consist of `gptel-permit.el` alone and SHALL
carry all rule-engine behavior — validation, matching, scopes, ids,
registry, hooks — with no module file required for meaningful operation.
The core's *code* (functions, `defvar`s, `declare`s, `require`s) SHALL
name no optional module symbol; optional modules appear only in
docstring prose and in `:type` widget choices left open
(`(symbol :tag "Registered action")`).

#### Scenario: Core stage-compiles alone
- GIVEN the staged `gptel-permit` package with only gptel on the load
  path
- WHEN byte-compiled in batch Emacs
- THEN compilation SHALL succeed.

#### Scenario: Core alone runs the engine
- GIVEN a fresh Emacs with only the staged core installed and
  `gptel-permit-mode` enabled
- WHEN a tool call passes through `gptel-permit--apply-rules`
- THEN validation, matching over the four scopes, built-in actions,
  ids, events and vetoes SHALL behave per the `rule-engine` and
  `rule-engine-hooks` capabilities with no missing-symbol error.
