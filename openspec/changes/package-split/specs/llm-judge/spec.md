# llm-judge Delta

## MODIFIED Requirements

### Requirement: Judge action form
The judge action handler shall remain registered on
`gptel-permit-action-handlers` under `judge`, and its ON-SAFE/ON-UNSAFE
slots shall accept every action symbol *registered at runtime* —
`allow`, `deny`, `ask` and a `sandbox` slot dispatched through the
registry like any other action.

The `sandbox` slot is a soft cross-package reference: when the
`gptel-permit-sandbox` package is installed and loaded, a SAFE/UNSAFE
resolution through the `sandbox` slot SHALL produce the sandbox args
rewrite verdict; when it is not loaded, the registry lookup SHALL miss
and the resolution SHALL fail closed to `(:confirm t)` — never an
unwrapped execution.

The judge module's decision-recording call into analytics
(`gptel-permit-analytics--record-decision` during programmatic
resolution) SHALL remain `fboundp`-guarded and unlisted in
`Package-Requires`: judge→analytics is not a dependency edge.

#### Scenario: Sandbox slot without the sandbox package
- GIVEN the judge and core packages are installed, the sandbox package
  is not, and the registry carries no `sandbox` entry
- WHEN a judge action with `(judge sandbox deny)` resolves to a SAFE
  verdict
- THEN the resolution SHALL be `(:confirm t)` with a log line naming the
  unregistered action, and the original command SHALL NOT be executed.

#### Scenario: Package-Requires names only the core
- GIVEN the judge module's file header
- THEN `Package-Requires` SHALL list `emacs`, `gptel` and
  `gptel-permit`, and SHALL NOT list `gptel-permit-analytics` or
  `gptel-permit-sandbox`.

### Requirement: Judge package boundaries
The judge module SHALL hard-require only `gptel` and the core
(`gptel-permit`), SHALL reference no sandbox or analytics file or symbol
in code (docstring prose naming the optional cooperation is permitted),
and SHALL stage-compile with only the staged core on the load path.

#### Scenario: Staged byte-compile with core only
- GIVEN the judge module is staged into its package directory with
  `gptel-permit.el` (the staged core) and no sibling modules on the load
  path
- WHEN it is byte-compiled in batch Emacs
- THEN compilation SHALL succeed with no "Cannot open load file" error.
