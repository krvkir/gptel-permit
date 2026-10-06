# analytics Delta

## MODIFIED Requirements

### Requirement: Analytics package boundaries
The analytics capability SHALL be distributed as the standalone
`gptel-permit-analytics` package, hard-requiring only `emacs`, `gptel`
and the core (`gptel-permit`), and SHALL stage-compile with only the
staged core on the load path.

Analytics' references to the judge and sandbox modules SHALL remain
soft and unlisted in `Package-Requires`:

- the judge's per-call state is read under
  `(featurep 'gptel-permit-judge)` and yields omitted JSONL fields when
  the judge package is absent;
- the sandbox's rewritten-args binding is consulted via a bare `defvar`
  declaration and an empty-binding fallback and yields uncorrelated
  (original-args) decision records when the sandbox package is absent;
- the `judge-verdict` event type is consumed from the open event
  vocabulary and simply never arrives when the judge package is absent.

No analytics record SHALL signal, and no captured record SHALL lose
fields, in any installed subset configuration.

#### Scenario: Core-and-analytics install records full chains
- GIVEN only the core and analytics packages are installed, analytics is
  registered, and a session/ask/decision chain completes
- THEN the JSONL log SHALL contain the `tool-call`, `rule-match`,
  `verdict`, `confirm` and `decision` events, with judge and
  rewrite-correlation fields absent, and no error SHALL be logged.

#### Scenario: Package-Requires names only the core
- GIVEN the analytics module's file header
- THEN `Package-Requires` SHALL list `emacs`, `gptel` and
  `gptel-permit`, and SHALL NOT list the judge or sandbox packages.

#### Scenario: Staged byte-compile with core only
- GIVEN the analytics module is staged with only `gptel-permit.el` on the
  load path from the staged tree
- WHEN it is byte-compiled in batch Emacs
- THEN compilation SHALL succeed with no "Cannot open load file" error.
