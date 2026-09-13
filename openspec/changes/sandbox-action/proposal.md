# Proposal: sandbox-action

## Why
Permissions and LLM judges reduce friction but are not security boundaries —
per-call classifiers are blind to multi-hop attack chains (cf. Embrace The
Red's auto-mode bypass). Actual isolation must come from the OS: run
`execute`-group tool calls inside a sandbox so the model can operate
unattended without being able to leave the project.

## What Changes
- New rule `:action sandbox`: rewrites the tool call's `:args` `:command`
  through a sandbox wrapper and returns `(:confirm nil :args …)` using gptel's
  officially supported args-rewrite hook return.
- Builtin backend: pure-elisp bubblewrap wrapper (no extra deps): read-only
  `/`, private tmpfs, project root writable, network off by default,
  environment scrubbed (`--clearenv` + whitelist), mandatory ro-binds for
  sensitive paths that exist (`.git`, `~/.ssh`, shell rc files, protected
  dirs).
- Opt-in Anthropic sandbox-runtime (`srt`) backend: defcustoms map to its
  settings JSON via `json-encode`; chosen explicitly (srt on Linux still
  needs node + socat + ripgrep; the unofficial PyPI `sandbox-runtime` port
  has the same requirements).
- Fail closed when the sandbox binary is unavailable: `(:confirm t)`.
- Rules and judge evaluate the ORIGINAL command; wrapping happens last,
  when the action fires.

## Capabilities

### New Capabilities
- `sandbox`: sandbox action dispatch, bwrap command builder, protected-path
  handling, srt settings mapping, fail-closed behavior, composition with
  rules/judge (original command is matched/judged before wrapping).

### Modified Capabilities
- `hook-integration`: return-value protocol gains the `:args` rewrite
  verdict (`(:confirm nil :args …)`) as a first-class outcome of rule
  actions.

## Impact
- `gptel-permit-sandbox.el` (new): defcustoms, wrapper builders, action fn.
- `gptel-permit.el`: one `pcase` arm in `gptel-permit--apply-rules`;
  `:action` type choice gains `sandbox`.
- Hook pipeline: a matched `sandbox` rule now returns
  `(:confirm nil :args <wrapped>)`; no other hook-behavior changes.
- External dep (builtin backend): bubblewrap only. srt backend is opt-in.
