# Tasks

## 1. Callable conditions (gptel-permit.el)
- [ ] Extract the four predicate cond-branches in `gptel-permit--match-rule-p`
      into named pure functions `gptel-permit--inside-project-p`,
      `--outside-project-p`, `--inside-protected-dirs-p`, `--path-traversal-p`
      taking `(value tool-call)`; preserve expand-file-name /
      file-in-directory-p logic exactly.
- [ ] Add defvar `gptel-permit--condition-predicates` alist (keyword ->
      function) seeded with the four built-ins.
- [ ] Rewrite condition dispatch in `gptel-permit--match-rule-p`: stringp ->
      regexp match; keywordp -> alist lookup (missing keyword => condition
      fails with logged warning); functionp -> funcall `(value tool-call)`.
      Keep cl-every sequential short-circuit and arg-group/'path placeholder
      expansion.
- [ ] Update `gptel-permit-global-rules` defcustom docstring/` :type` to
      document "string | keyword | function" condition values.
- [ ] Wrap `gptel-permit--apply-rules` body in `condition-case` returning
      `(:confirm t)` on unexpected error (gptel demotes hook errors to nil =
      fail-open without this).
- [ ] Keep all functions < 60 lines.

## 2. Judge (gptel-permit-judge.el, new)
- [ ] Defcustoms: `gptel-permit-judge-backend` (nil), `gptel-permit-judge-model`,
      `gptel-permit-judge-timeout` (15), `gptel-permit-judge-policy` (""),
      `gptel-permit-judge-history-entries` (0); defvar-local
      `gptel-permit--last-judge-rationale`.
- [ ] `gptel-permit--judge-build-prompt` (pure): blast-radius preamble
      (system-wide settings, package installs, network egress, writes
      outside project/tmp, written-then-executed or download-execute chains,
      secrets access) + user policy + TOOL CALL block + optional history.
- [ ] `gptel-permit--judge-history`: when entries > 0, `with-current-buffer`
      on `(get-buffer (plist-get tool-call :buffer))`, `gptel--parse-buffer`,
      last N entries, truncated.
- [ ] `gptel-permit--judge-request-sync`: blocking `gptel-request` with
      let-bound backend/model, tools/context/stream nil,
      accept-process-output spin with timeout, `condition-case`,
      `with-local-quit`; returns response string or nil.
- [ ] `gptel-permit--judge-parse-verdict` (pure): string -> `(SAFE . rationale)` |
      `(UNSAFE . rationale)` | nil (misparse).
- [ ] `gptel-permit-judge-safe-p`: orchestrate; store rationale; log verdict;
      boolean return; every failure path nil.
- [ ] `(provide 'gptel-permit-judge)`.

## 3. Tests (mocks via cl-letf on gptel-request and judge internals)
- [ ] Conditions: dispatch per type; callable receives (value tool-call);
      first-nil short-circuit (later condition's callable not invoked);
      custom keyword via alist; legacy keyword results unchanged.
- [ ] Judge parse: "SAFE", "SAFE\nwhy", "UNSAFE\nwhy", garbage, empty.
- [ ] Judge sync via stubbed `gptel-request`: SAFE -> t; UNSAFE -> nil;
      nil response -> nil; timeout -> nil; backend nil -> nil;
      history-entries 0 -> prompt has no history; = 2 -> history included.
- [ ] Integration: rule `(:action ask)` with judge condition fires only when
      stubbed judge returns t; otherwise next rule handles.
- [ ] `make test` passes; byte-compile clean.

## 4. Docs
- [ ] README: callable-conditions authoring; judge section with disclaimer
      (convenience, not a security boundary; deny-only semantics via rule
      fallthrough; pair with sandbox; keep deny rules ahead of judge rules).
- [ ] AGENTS.org: add `gptel-permit-judge.el`; correct that the hook plist's
      `:buffer` is a buffer NAME string and `:backend` the struct; the
      registered hooks are `--validate-args` and `--apply-rules`.
