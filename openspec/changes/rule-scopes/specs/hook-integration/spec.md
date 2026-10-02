# hook-integration Delta

## MODIFIED Requirements

### Requirement: Keybinding
gptel-permit-mode SHALL bind `C-c C-b` in `gptel-tool-call-actions-map` to `gptel-permit-add-rule`.

The wizard SHALL ask for the target scope as its last question, after the
tool target, the conditions, and the action, offering the scopes of
`gptel-permit-rule-scopes` and defaulting to `session` — so accepting the
default keeps the previous behavior exactly: the rule goes into
`gptel-permit-rules` and the pending calls are resolved as before. A
non-default answer SHALL store the rule in the chosen scope /only/ and
SHALL NOT duplicate it into the session's rules.

The scope answer SHALL affect only where the rule is stored: the pending
tool calls SHALL be accepted or rejected exactly as today for every
scope, and the verdict SHALL NOT depend on the chosen scope.

A storage failure — an unwritable file, an error while saving — SHALL be
reported to the user and SHALL not silently lose the rule the user just
created: the rule SHALL remain in effect for the session through the
session's rules.

#### Scenario: Interactive rule creation via keybinding
- GIVEN a tool-call confirmation overlay is displayed to the user
- AND `gptel-permit-mode` is active
- WHEN the user presses `C-c C-b`
- THEN `gptel-permit-add-rule` SHALL be invoked
- AND the user SHALL be prompted to select a tool call, argument, regexp, and action
- AND the new rule SHALL be added to `gptel-permit-rules` (the default
  scope being `session`)
- AND it SHALL be applied immediately to pending tool calls.

#### Scenario: Scope is the last question, defaulting to session
- GIVEN the wizard has collected the tool target, the conditions and the
  action
- WHEN the scope prompt is shown
- THEN it SHALL offer `session`, `notebook`, `project` and `global`
- AND the default answer SHALL be `session`
- AND no storage outside the buffer SHALL be touched when the default is
  accepted.

#### Scenario: Choosing notebook persists into the notebook
- GIVEN an Org or markdown notebook buffer and the wizard answered with
  scope `notebook`
- WHEN the rule is created
- THEN the rule SHALL be written into the notebook's own storage
  (`GPTEL_PERMIT_RULES` property, or the `gptel-permit-notebook-rules`
  local variable)
- AND the pending calls SHALL be resolved with the chosen action.

#### Scenario: A disabled scope is not offered
- GIVEN the `project` entry has been removed from the scope
  configuration
- WHEN the scope prompt is shown
- THEN `project` SHALL NOT be among the offered answers
- AND only the scopes still configured SHALL be offered.

#### Scenario: Choosing global persists through Custom
- GIVEN the wizard answered with scope `global`
- WHEN the rule is created
- THEN `gptel-permit-global-rules` SHALL gain the rule through the
  Customize machinery
- AND the pending calls SHALL be resolved with the chosen action.

#### Scenario: Non-default scopes do not duplicate into the session
- GIVEN the wizard answered with scope `project`
- WHEN the rule is created
- THEN the project store SHALL contain the rule
- AND `gptel-permit-rules` SHALL NOT gain a copy of it.

#### Scenario: Persistence failure keeps the rule for the session
- GIVEN a notebook whose file cannot be written and a wizard answer of
  scope `notebook`
- WHEN the rule is created
- THEN the failure SHALL be reported to the user
- AND the rule SHALL be present in `gptel-permit-rules` for the
  remainder of the session
- AND matching SHALL keep honoring it while the session lasts.

## Implementation details

- The offered scope symbols are those of the ordered configuration list
  `gptel-permit-rule-scopes`; the prompt default is `session`.
- A non-session answer stores the rule through that scope's registered
  `:writer`; the global writer is `customize-save-variable`. On success
  no session copy is pushed — session is the first scope, so a shadow
  copy would make the next calls' log lines and every downstream
  analytics record report scope `session` instead of the scope the user
  chose. Pending-call resolution does not need the copy either: the
  wizard calls gptel's accept/reject commands directly on the pending
  calls, it does not re-run matching. On writer error the error is
  caught, logged, and reported, and the rule is pushed into
  `gptel-permit-rules` as the fallback.
- The three non-session stores are readable immediately after the write
  (the Org property is in the buffer, the markdown variable is
  buffer-local, the project store's cache is refreshed by the writer),
  so the next tool call already sees the rule in its own scope.
- This requirement also corrects the baseline text that named
  `gptel-permit-confirm-or-add-rule`, a function that does not exist:
  the command is `gptel-permit-add-rule`.
