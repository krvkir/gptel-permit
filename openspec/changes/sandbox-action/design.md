# Design: sandbox-action

## Context
gptel's pre-tool hooks may return `(:args …)` to rewrite a tool call's
arguments (merged into the executing call object, the LLM-visible history,
and the confirm UI). gptel-agent's Bash tool runs `bash -c` via a process.
Wrapping `:command` in a sandbox prefix therefore sandbox-executes the call
without advising any tool implementation. Reads are left unrestricted so the
sandboxed tree matches what in-process tools (Read/Grep) see; only writes
outside writable dirs and network differ, and those fail with deterministic
OS errors that are fed back to the model.

## Goals / Non-Goals
Goals: unattended arbitrary code execution inside a boundary; zero-dep
default; fail closed; mandatory sensitive-path protection. Non-goals:
network domain allowlists in the builtin backend (proxy territory — srt
backend or v2); sandboxing Write/Edit (in-process Emacs, not process-level);
sandboxing Eval (separate stretch item); Docker/podman backends.

## Decisions
- **Builtin bwrap first, srt opt-in.** `gptel-permit-sandbox-backend`
  (`auto|builtin|srt`, default auto → builtin unless srt explicitly chosen).
  srt needs node+socat+ripgrep on Linux for its network layer; the PyPI
  `sandbox-runtime` (srt-py) mirror has identical requirements, so it is not
  a lighter path. Builtin gives mac/windows nothing (documented) — bwrap is
  Linux-only.
- **`:args` rewrite**, not advice. Officially supported; keeps tool
  implementations untouched; confirm UI shows the wrapped command.
- **Boundary crossing = OS error to the LLM; escape hatch = rule order.**
  No auto "retry outside sandbox" (that's Claude's dangerouslyDisableSandbox
  anti-pattern without a human). Commands needing boundary access match an
  `ask` rule placed above the sandbox rule and run unsandboxed after user
  confirm. A retry counter forces human triage after N consecutive failures.
- **Mandatory protections** folded into the wrapper regardless of rules:
  `<root>/.git` (hooks+config), `~/.ssh`, `~/.gnupg`, shell rc files,
  `gptel-permit-protected-dirs` — ro-bound when they exist at wrap time.
  Linux limitation inherited from bwrap: only existing paths can be bound;
  documented.
- **Composition order**: `--apply-rules` evaluates conditions/judge on the
  original `:command`; the `sandbox` action wraps last. This preserves
  readable regexps and honest judge input.

## Risks / Trade-offs
- Env leakage → `--clearenv` + `gptel-permit-sandbox-env-keep`
  (PATH HOME LANG LC_ALL TERM TMPDIR).
- Model confusion between Grep-tool and Bash-grep behavior → reads
  unrestricted (no divergence); only writes/network differ; README notes.
- bwrap argv mis-quoting → single `shell-quote-argument` on the whole
  original command wrapped as `bash -c <quoted>`; tested.
- Backend missing → `(:confirm t)`, and whole `--apply-rules` body is under
  `condition-case` → `(:confirm t)`.

## Migration Plan
New file + one pcase arm; opt-in rules in README. Rollback: remove the
sandbox rule from user config.

## Open Questions
None blocking. srt backend ships documented-but-untested on this box.
