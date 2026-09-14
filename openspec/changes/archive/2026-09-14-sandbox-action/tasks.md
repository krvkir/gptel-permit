# Tasks

## 1. Sandbox (gptel-permit-sandbox.el, new)
- [x] Defcustoms: `gptel-permit-sandbox-backend` (auto), `-command` ("bwrap"),
      `-network` (nil), `-writable-dirs` (nil → project root),
      `-env-keep` (PATH HOME LANG LC_ALL TERM TMPDIR), `-allowed-domains`
      (nil, srt only), `-extra-args` (nil).
- [x] `gptel-permit--sandbox-protected-paths` (project .git, ~/.ssh,
      ~/.gnupg, shell rc files, protected-dirs; filter `file-exists-p`).
- [x] `gptel-permit--sandbox-wrap-bwrap` (pure builder per spec shape;
      `shell-quote-argument` the original command once).
- [x] `gptel-permit--sandbox-settings-json` + `--sandbox-wrap-srt`
      (json-encode settings to a cache file; wrap as srt CLI).
- [x] `gptel-permit--sandbox-action`: pick backend, fail closed when binary
      missing, wrap, return `(:confirm nil :args (:command wrapped))`; log.
- [x] pcase arm `('sandbox …)` in `gptel-permit--apply-rules` dispatching to
      the action function; add `sandbox` to the `:action` type choice.
- [x] Boundary-failure retry counter (buffer-local): after 3 consecutive
      sandboxed-command failures, force `(:confirm t)` with a note (human
      triage); reset on any success or user decision.
- [x] `(provide 'gptel-permit-sandbox)`.

## 2. Tests
- [x] Wrapper argv matrix: quoting of tricky commands, `--unshare-net`
      toggle, writable dir binds, ro-binds only for existing paths, env
      keep-list honors unset vars.
- [x] Protected paths: `.git` ro-bind present; nonexistent rc file skipped.
- [x] srt: settings JSON maps writable-dirs/allowed-domains; command shape.
- [x] Action verdicts: `(:confirm nil :args …)` on success; `(:confirm t)`
      when `executable-find` stubbed nil; original command used for rule
      match, wrapped command only in returned args.
- [x] Rule-order escape hatch: ask rule above sandbox returns original
      command with `(:confirm t)`.
- [x] `make test` passes; byte-compile clean.

## 3. Docs
- [x] README: sandbox section (recipes: sandbox-on-execute;
      judge-gated sandbox composed with the judge condition; ask rules above
      sandbox for boundary-crossing commands; known limitations — Linux
      mandatory denies only cover existing files, no syscall filtering,
      Write/Edit not covered, network is binary on/off in builtin backend);
      srt opt-in setup notes; threat-model disclaimer.
- [x] AGENTS.org: add `gptel-permit-sandbox.el` to project structure.
