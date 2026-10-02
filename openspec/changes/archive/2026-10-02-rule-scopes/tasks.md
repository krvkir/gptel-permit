# Tasks

## 1. Scope registry and engine walk (gptel-permit.el)

- [x] 1.1 Add `defvar gptel-permit-rule-scopes`: ordered alist
      `session`/`notebook`/`project`/`global`, each value a plist with
      `:reader` and `:writer`; docstring states that the order *is* the
      match order and that removing an entry disables the scope.
      Verify: `(mapcar #'car gptel-permit-rule-scopes)` reads
      `(session notebook project global)`.
- [x] 1.2 Rewrite `gptel-permit--find-action` to walk the registry into a
      `(RULE . SCOPE)` walk: collect `(SCOPE READER)` in registry order,
      call each reader, and return the first matching rule together with
      its scope (the rule carries its `:origin`, so callers get the
      origin from the rule). Keep the `:rule-match` emission point
      exactly where it is (inside the loop on the first match, once with
      nil after all fail) and keep the two-value return contract for
      callers. Verify: `make test` still green.
- [x] 1.3 Add the internal collector `gptel-permit--scoped-rules` taking
      no arguments, returning a list of `(RULE . SCOPE)` in registry
      order; document that readers are called in the session buffer,
      that each returned rule carries an `:origin` plist attached by
      its reader (any store-supplied origin overwritten; the collector
      attaches `(:scope session)` / `(:scope global)` to session and
      global rules itself), that origins are inert during matching and
      stripped by writers, and that reader errors deliberately
      propagate.
- [x] 1.4 Add the trivial session reader/writer
      (`gptel-permit--read-session-rules` → `gptel-permit-rules`;
      `gptel-permit--write-session-rule` → `(push rule gptel-permit-rules)`)
      and the trivial global reader/writer
      (`gptel-permit--read-global-rules` → `gptel-permit-global-rules`;
      writer → `customize-save-variable 'gptel-permit-global-rules`).
      Verify: ERT covers the global writer updating the running value.
- [x] 1.5 Update `gptel-permit--apply-rules` to rebind from the new
      `--find-action` shape (matching rule + scope), attach `:rule-scope`
      and the rule's `:origin` (as `:rule-origin`) to the enriched call
      before the `:rule-match` emission, and log the matching scope and
      origin. Do not change the verdict computation, the veto
      consult, or the top-level `condition-case`.
      Verify: existing `:verdict`/`:confirm` assertions in
      `tests/gptel-permit-rule-engine-hooks-test.el` unchanged and green.
- [x] 1.6 Extend the `tests/gptel-permit-rule-engine-test.el`
      first-match-wins cases to the registry: session over global,
      notebook over project+global, project over global, deferral only
      after every scope is exhausted, and a no-persisted-stores run whose
      verdict equals the old session+global behavior. Add a scope-removal case
      (delete the `project` entry, project rules stop contributing) and a
      no-storage case (every reader returns nil).
      Verify: `make test` green, new ERT tests named for the spec
      scenarios.
- [x] 1.7 Extend the "Diagnostic Logging" test to assert the matched scope
      appears in `*gptel-permit-log*` and that a no-match log names no
      scope. Verify: the log test passes with
      `gptel-permit-log-enabled` let-bound to t.
- [x] 1.8 Update the `gptel-permit-rules`, `gptel-permit-global-rules`,
      `gptel-permit-rule-scopes` and `gptel-permit-add-rule` docstrings to
      describe the four scopes, the precedence order, and where each scope
      is stored. Verify: `emacs-lisp-byte-compile` clean on
      `gptel-permit.el`.

## 2. Notebook scope: Org storage (gptel-permit.el)

- [x] 2.1 Add `gptel-permit--read-notebook-rules`: when
      `(derived-mode-p 'org-mode)` and `(require 'org nil t)` succeeds,
      resolve the value inside `org-with-wide-buffer` as
      `(or (org-entry-get (point) "GPTEL_PERMIT_RULES" t)
      (gptel-permit--notebook-org-file-level-value))`, then `read` it.
      Normalize the read result to a list of rules (a value whose car is
      a keyword is a single rule and is wrapped). The reader SHALL NOT
      catch read errors (an unreadable property propagates into the
      engine's fail-closed `condition-case`). Otherwise nil, and nil when
      neither lookup finds a value. `declare-function` `org-entry-get` and
      `org-with-wide-buffer` (`org-macs`) so byte-compiling does not warn.
      Verify: an ERT test with a temp `org-mode` buffer holding a
      file-level drawer returns the rule list; a text-mode buffer returns
      nil; an unbalanced property value signals rather than returning nil.
- [x] 2.2 Add `gptel-permit--notebook-org-file-level-value`: find the
      first `:[ \t]*GPTEL_PERMIT_RULES:[ \t]*VALUE` line before the first
      headline (`outline-next-heading`) and return VALUE, else nil. This
      is the step `org-entry-get` cannot do (it misses a drawer that
      follows a keyword line).
      Verify: an ERT test with the layout `#+TITLE:` then drawer returns
      the value, and one with the drawer first also returns it.
- [x] 2.3 Add `gptel-permit--notebook-org-file-level-line`: position of
      that property line, or nil, for the writer's in-place branch.
      Verify: ERT asserts nil for a notebook whose only drawer is inside a
      heading.
- [x] 2.4 Add `gptel-permit--write-notebook-rule` for Org: compute the
      merged list as the *file-level* value (group 2.2) plus the new rule
      — not the reader's full value, which may be a heading override —
      strip any `:origin` fields, `prin1-to-string` it, and either
      replace the existing file-level property line's value in place
      (group 2.3's position, with `inhibit-read-only`) or, when no
      file-level line exists, do the `goto-char (point-min)` /
      `org-at-heading-p` / `org-open-line` dance and `org-entry-put`. Do
      not save the buffer; do not touch a heading's own drawer.
      Verify: ERT asserts (a) read-after-write round-trip `equal`, (b) a
      second write leaves exactly one `GPTEL_PERMIT_RULES` line, (c) a
      notebook whose only drawer is in a heading gains the file-level
      property and keeps the heading's value unchanged, and (d) writing
      from inside a heading whose value differs does not copy that
      heading value into the file-level list.
- [x] 2.5 Add the ERT tests for the spec's Org scenarios: file-level
      value governs the whole notebook; a drawer after `#+TITLE` is still
      found; a heading value wins inside its subtree; the nearest ancestor
      heading wins over the file-level value for a nested heading; an
      absent property returns nil; the reader works under narrowing; a
      heading's rules carry an origin naming that heading and a
      file-level read's rules carry a file-level origin.
      Verify: `make test` green; the scenario tests fail if inherit `t` is
      changed to `'selective` or if the file-level fallback is removed.

## 3. Notebook scope: markdown storage (gptel-permit.el)

- [x] 3.1 Add `defvar-local gptel-permit-notebook-rules` and give it a
      `safe-local-variable` property with a list predicate, plus the
      autoloaded `(put ...)` form so the property is known before the
      package loads. Verify: `(safe-local-variable-p
      'gptel-permit-notebook-rules '((:tool "B" :action allow)))` → t.
- [x] 3.2 Complete the notebook reader/writer dispatch for non-Org
      notebooks: the non-Org branch of `gptel-permit--read-notebook-rules`
      returns `gptel-permit-notebook-rules` with
      `(list :scope 'notebook :file (buffer-file-name))` origins
      attached; `gptel-permit--write-notebook-rule` sets the buffer-local
      variable and `add-file-local-variable 'gptel-permit-notebook-rules`
      with the printed list, `:origin` fields stripped; do not save the
      buffer. The mode dispatch SHALL call group 2.4's Org writer under
      `org-mode` and this one otherwise.
- [x] 3.3 Add ERT tests: writing produces a `Local Variables:` block
      containing `gptel-permit-notebook-rules`; re-visiting the written
      file in a fresh buffer sets the variable to the written list with no
      local-variables prompt (`enable-local-variables` left at its
      default); an Org buffer never touches the file-local mechanism.
      Verify: `make test` green, and the markdown test asserts the buffer
      text, not just the variable.
- [x] 3.4 Document the markdown scope's dependency on
      `enable-local-variables` in the variable docstring.
      Verify: docstring readable via `C-h v`.

## 4. Project scope (gptel-permit.el)

- [x] 4.1 Add `defcustom gptel-permit-project-rules-enabled` (boolean,
      default t, group `gptel-permit`) with a docstring stating the store
      file name, that reading it is equivalent in trust to a repository's
      `.dir-locals.el`, and that nil disables the scope.
      Verify: customize shows the option; `(gptel-permit--read-project-rules)`
      returns nil when it is let-bound to nil.
- [x] 4.2 Add `gptel-permit--project-rules-chain`: the directory chain
      from the notebook's directory up to and including
      `gptel-permit--project-root`, nearest first; nil when no root
      resolves. Keep `gptel-permit--project-rules-file` as the root
      store's path, for the writer. Verify: with `default-directory`
      two levels under a git repo's root the chain lists both
      directories, root last; with no project and no file it is nil.
- [x] 4.3 Add the pure parser `gptel-permit--parse-project-rules`: read
      every top-level form from a buffer with a
      `(condition-case nil (read (current-buffer)) (end-of-file nil))`
      loop and `read-circle` bound to nil. `invalid-read-syntax` and any
      other read error SHALL escape (the reader catches nothing, so the
      engine fails the call closed); per-rule shape checking is the
      validation pass in group 5, not the parser's job.
      Verify: ERT covers comments plus two forms, an empty file (nil), and
      a `#.` form (error escapes to the caller).
- [x] 4.4 Add the per-file mtime-keyed cache
      (`gptel-permit--project-rules-cache`, an alist keyed by the
      absolute store file name, each entry `(MTIME . RULES)`) so an
      unchanged store is not re-read; invalidate on mtime change and on
      `gptel-permit-project-rules-enabled` turning nil. Verify: ERT
      counts reads across two calls with an unchanged chain, then
      touches one store of it and counts again.
- [x] 4.5 Add `gptel-permit--read-project-rules` and
      `gptel-permit--write-project-rule`: the reader walks
      `gptel-permit--project-rules-chain` nearest-first, concatenating
      the parsed rules of every existing store and attaching
      `(list :scope 'project :file STORE)` origins (a store-supplied
      origin field is overwritten); the writer appends the printed form
      of the origin-stripped rule plus a newline to the root store only,
      creating it when missing, never writing outside the project root,
      no temp-file rename so concurrent readers see the old content
      until the append lands. Verify: read-after-write round-trip; a
      test asserting the file path stays inside the project root; a
      test asserting the origin names the right store for rules from
      two different stores in one chain.
- [x] 4.6 Add ERT tests for the spec's project scenarios: rule matches a
      notebook in the project; nil when no project resolves; comments and
      multiple forms parse in file order; disabled option reads nothing.
      Verify: `make test` green.
- [x] 4.7 Add ERT tests for the chain semantics: an inner store's Bash
      `allow` decides over the root store's Bash `ask` while the root
      store's Read `deny` still binds for Read ("nearest decides,
      broader fills"); a store above the project root is not read; a
      broken store anywhere in the chain fails calls closed. Verify:
      `make test` green.

## 5. Persisted-rule validation (gptel-permit.el)

- [x] 5.1 Add the pure predicate `gptel-permit--valid-persisted-rule-p`:
      a non-empty list whose keys are all keywords, and whose every
      condition value is a string, a keyword, or a symbol that names a
      function; reject cons/lambda condition values and non-plist values.
      Verify: an ERT table over valid rules (regexp, predicate keyword,
      function symbol, tool-group, no conditions) and invalid ones
      (lambda condition, `(:conditions "x")`, a bare string, a nested
      list where a plist is expected).
- [x] 5.2 Apply the predicate in the notebook and project readers only:
      keep valid rules, skip invalid ones with a
      `gptel-permit--log` line naming the scope. Do not validate
      `gptel-permit-rules` or `gptel-permit-global-rules`.
      Verify: ERT asserts a session rule with a lambda condition still
      matches (existing behavior) while a project store with one is
      skipped.
- [x] 5.3 Add ERT tests for the spec's validation scenarios: lambda in a
      project store is skipped and a matching global rule decides;
      a named function symbol in a project store is accepted and called;
      malformed notebook data does not break a later valid rule.
      Verify: `make test` green.
- [x] 5.4 Add the fail-closed ERT test: an unparseable project store makes
      `gptel-permit--apply-rules` return `(:confirm t)` even with a
      matching global `allow` rule. Verify: the test asserts the verdict,
      not merely that an error was signaled.

## 6. Wizard scope question (gptel-permit.el)

- [x] 6.1 Add the last wizard question: `completing-read` over the scope
      symbols of `gptel-permit-rule-scopes` with `session` as the default,
      placed after the action prompt; keep the accept/reject path and the
      `(push rule gptel-permit-rules)` line unchanged.
      Verify: an ERT test with stubbed prompts asserts the question is
      asked last and that answering the default leaves the session
      variable identical to today's result.
- [x] 6.2 Dispatch persistence: for a non-session scope call that scope's
      `:writer`; on writer failure catch the error, log it, and keep the
      session copy. Do not push a copy into `gptel-permit-rules` for a
      successful non-session persist.
      Verify: ERT stubs a scope writer and asserts (a) it was called with
      the rule, (b) the session copy is absent on success, (c) it is
      present on writer error.
- [x] 6.3 Add ERT tests for the spec's wizard scenarios: notebook answer
      writes the Org property; notebook answer in a markdown buffer writes
      the file-local variable; global answer goes through
      `customize-save-variable` (stub or a temp `custom-file`); project
      answer appends to the project store and leaves
      `gptel-permit-rules` without a copy.
      Verify: `make test` green, including the pre-existing
      keybinding test that asserts `C-c C-b` → `gptel-permit-add-rule`.

## 7. Scope reporting: log, event, analytics

- [x] 7.1 Assert in `tests/gptel-permit-rule-engine-hooks-test.el` that an
      observer sees `:rule-scope` and `:rule-origin` on the tool call at
      the `:rule-match` event and at `:verdict`, and that the payload
      shapes are unchanged (`nil` for `:tool-call`, the action symbol for
      `:rule-match`, `(ACTION . VERDICT)` for `:verdict`).
      Verify: `make test` green; the triple-recording observer test names
      the scope and origin per scenario.
- [x] 7.2 Add the no-match assertion: no matched scope and no origin on
      the call when no rule matched. Verify: ERT asserts
      `(plist-member tc :rule-scope)` and `(plist-member tc :rule-origin)`
      are nil or their values nil.
- [x] 7.3 Emit `scope` in the analytics `rule-match` and `verdict` events
      by reading `:rule-scope` off the enriched tool call in
      `gptel-permit-analytics--emit-rule-match` /
      `--emit-verdict`; convert to a string with `symbol-name`; omit the
      field when absent.
      Verify: an ERT test over the JSONL fixture asserts `"scope"` on
      both events for a notebook match and its absence for a no-match
      call.
- [x] 7.4 Add the legacy-folding test: a fixture whose records carry no
      `scope` field still folds into outcome rows, with the analytics
      compute path unchanged. Verify: `make test` green and the fixture
      test asserts row counts, not just absence of error.
- [x] 7.5 Add the `scope` field and the new record examples to
      `openspec/specs/analytics/spec.md`'s event-schema text if the delta
      text diverges from what the code writes. Verify:
      `openspec validate rule-scopes --strict` passes and the README's
      sample JSONL line carries `scope`.

## 8. Documentation (README.org)

- [x] 8.1 Add a "Rule scopes" section: the precedence table (session →
      notebook → project → global), where each scope lives, the
      nearest-value-wins rule for Org heading properties, the
      nearest-decides/broader-fills rule for project store chains, and
      the note that the wizard's notebook writes always land in the
      file-level drawer. Also note the log names the exact source of a
      matched rule — the store file, the heading, or the file level.
      Verify: the section's stated file paths match
      `gptel-permit--project-rules-file` and the reader implementations.
- [x] 8.2 Document the two notebook formats with copy-pasteable examples:
      an Org `:GPTEL_PERMIT_RULES:` property and a markdown
      `Local Variables:` block, both holding the same printed rule.
      Verify: pasting each example into a fresh notebook and evaluating
      `(gptel-permit--read-notebook-rules)` returns that rule.
- [x] 8.3 Document the project store, including the trust caveat (any
      directory inside the project may hold a store, not only the root),
      the nearest-decides/broader-fills semantics, the walk's root
      boundary, and `gptel-permit-project-rules-enabled`, next to the
      existing `gptel-permit-protected-dirs` guidance.
      Verify: the README names the exact option and file name the code
      uses.
- [x] 8.4 Update the "How It Works" step that says session rules are
      checked first, followed by global rules, and the wizard bullet that
      says the rule is added to the session rules list.
      Verify: grep the README for "session-local rules ... global rules"
      and "session rules list"; both sentences reflect the registry order
      and the scope question.
- [x] 8.5 Change the "Default Global Rules" section only if the default
      `gptel-permit-global-rules` value changed (it does not); otherwise
      leave it and note in the scopes section that a user can move any
      global rule into a narrower scope. Verify: no stale reference to a
      session-then-global model remains in the README.

## 9. Integration verification

- [x] 9.1 `make test` green with all suites loaded, including the new
      `tests/gptel-permit-rule-scopes-test.el` added to the `Makefile`'s
      load list.
- [x] 9.2 Byte-compile every `.el` in the repo and require zero new
      warnings (`cl-declare`/`declare-function` in place for
      `org-entry-get`, `org-entry-put`, `add-file-local-variable`,
      `customize-save-variable`).
- [x] 9.3 `openspec validate rule-scopes --strict` passes.
- [x] 9.4 Manual end-to-end: in a git repository, create
      `gptel-permit-rules` with an allow rule, open an Org notebook in
      that repository, and confirm (a) a matching call auto-approves,
      (b) the log names scope `project` and the store file, (c) the
      analytics JSONL `rule-match` record carries `"scope":"project"`.
- [x] 9.5 Manual end-to-end: with a markdown notebook, answer the wizard
      with `notebook`, save the file, kill the buffer, reopen it, and
      confirm the rule is present and the call auto-approves in the fresh
      session with no local-variables prompt.
- [x] 9.6 Confirm the no-store baseline: in a directory with no project
      and no notebook stores, the verdict for a call matching a global
      rule is identical to the pre-change behavior (compare against a
      stash of the old `--find-action`).
