# Tasks

## 1. Analytics core (gptel-permit-analytics.el, new)
- [ ] Defcustoms: `gptel-permit-analytics-enabled` (nil), `-file`
      (under user-emacs-directory), `-sample-rate` (0.2).
- [ ] JSONL append helper (0600 permissions; truncated arg values) and per
      -call id allocator keyed by (buffer-name tool equal-args) FIFO queue.
- [ ] Event emitters wired (gated on enabled) into `gptel-permit--apply-rules`
      (tool-call, rule-match, verdict) and into
      `gptel-permit-judge-safe-p` (judge model/verdict/rationale on the
      verdict event, via `gptel-permit--last-judge-rationale`).
- [ ] Audit sampling at verdict time: enabled + automation-allow +
      `(< (random 100) (* rate 100))` → return `(:confirm t)` + audit event;
      never sample blocks.
- [ ] Advice on `gptel--accept-tool-calls` / `--reject-tool-calls` /
      `--steer-tool-calls` recording decision events with wait-ms
      (choice allow / cancel / steer; cancel non-terminal).
- [ ] `gptel-permit-register-analytics-hooks` /
      `gptel-permit-unregister-analytics-hooks` (idempotent; register sets
      enabled t and installs advice; unregister removes everything).

## 2. Reporting
- [ ] `gptel-permit-analytics-compute` (pure): parse JSONL -> totals,
      per-tool, daily/weekly/monthly, false-allow stats with inline Wilson
      95% CI (z=1.96).
- [ ] `gptel-permit-analytics-report` (interactive): render the computed
      structure into `*gptel-permit-analytics*`.

## 3. Tests
- [ ] Off by default: no file created, no advice present, no sampling.
- [ ] Enabled: events written with monotonic timestamps and shared ids;
      decision advice captures allow/cancel/steer with wait-ms.
- [ ] Sampling: stubbed `random` forces and skips; deny never sampled.
- [ ] Compute: fixture JSONL -> expected counts, rates, and Wilson interval.
- [ ] Register/unregister idempotent; unregister restores no-advice state.
- [ ] `make test` passes; byte-compile clean.

## 4. Docs
- [ ] README: analytics section — local-only rationale, enablement recipe in
      `use-package :config`, sample-rate meaning (audits automation allows;
      only active with analytics), report usage, privacy note (0600,
      truncated values, file contents warning), fragile-internal advice
      caveat for the three gptel commands.
- [ ] AGENTS.org: add `gptel-permit-analytics.el` to project structure.
