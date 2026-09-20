## Why

The sandbox's rough edges from first use: `auto` is a misleading alias for the builtin wrapper (spec and docstring even disagree about what it resolves to), `builtin` hides that the backend is bubblewrap, and macOS/Windows get no sandboxing at all instead of degrading sensibly. The protected-path list is duplicated between `gptel-permit-protected-dirs` and hardcoded sandbox entries, the failure-streak auto-resets with no way to reset it deliberately, and there is no interactive escape hatch to run a command inside the sandbox on demand. The mechanism is also welded to Bash-only rewriting with no extension point for the next tool (Eval needs entirely different sandbox mechanics).

## What Changes

- **BREAKING**: rename backend symbol `'builtin` → `'bwrap` (`gptel-permit-sandbox-backend` values become `auto`/`bwrap`/`srt`).
- `auto` becomes a real resolver: on Linux resolve to `bwrap`; on other platforms resolve to the first /available/ registered backend (`srt` when its binary is installed), else nil — and nil resolves the sandbox action to fail-closed `(:confirm t)` with a logged reason. The resolver picks among registered backends, so user-registered backends participate automatically.
- Pluggable backend registry `gptel-permit-sandbox-backends`: alist `SYMBOL → (:available-p FN :wrap FN)` with `bwrap` and `srt` as shipped entries; `:wrap (command root) → wrapped string`. Third parties add their own entries; the sandbox action, hotkey, and resolver all dispatch through the registry.
- Tool adapter registry `gptel-permit-sandbox-adapters`: alist `"TOOL-NAME" → (:wrap-args FN)` where the adapter rewrites a tool call's args plist into sandboxed args. Ships with a `"Bash"` adapter (wraps `:command` via the resolved backend); a call for a tool without an adapter fails closed `(:confirm t)` with a message — this is the extension point where the future `Eval` adapter (sandboxed Emacs subprocess running the expression) will land, without touching the sandbox core.
- Single source of truth for protected paths: `gptel-permit-protected-dirs` gains `./.git` in its default value and supports a `./` prefix meaning "relative to the project root" (new shared helper `gptel-permit--expand-protected-dir`, used by both the `:inside-protected-dirs` predicate and the sandbox). The sandbox drops its hardcoded `ROOT/.git`, `~/.ssh`, `~/.gnupg` entries and derives all protected paths from the option (plus its rc-files constant). **BREAKING** for users who customized `gptel-permit-protected-dirs` (defaults change; per project reality there are no such users yet).
- Failure streak becomes a sticky latch: when `gptel-permit-sandbox-retry-limit` consecutive sandboxed failures are hit, the buffer stays latched (every sandbox verdict = `(:confirm t)`) until a sandboxed command succeeds or the user runs the new `M-x gptel-permit-sandbox-reset`. No more silent auto-reset on trip. `gptel-permit-sandbox--remember`'s docstring explains its result-attribution purpose.
- Interactive sandboxing: `C-c C-s` (`gptel-permit-accept-tool-calls-sandboxed`) in `gptel-tool-call-actions-map` rewrites the pending tool calls through the adapter registry and accepts them — all-or-nothing: any adapterless tool in the pack refuses the whole acceptance with a message (plain `C-c C-c` remains available for unwrapped acceptance).

## Capabilities

### New Capabilities
- `sandbox-extension`: the backend registry, the tool adapter registry, and the resolution/fail-closed contract for `auto` — the customization surface that lets users plug their own sandbox mechanisms and add tool-specific rewriting.

### Modified Capabilities
- `sandbox`: backend naming (`bwrap`), protected-path sourcing from `gptel-permit-protected-dirs` (no hardcoded list), the sticky failure latch with explicit reset, and the `auto` resolution semantics.
- `rule-engine`: `:inside-protected-dirs` gains project-root-relative `./` semantics shared with the sandbox; `gptel-permit-protected-dirs` default gains `./.git`.
- `analytics`: the pending-confirmation key must not orphan when args are rewritten between confirm and accept (hotkey/judge-sandbox paths); the decision event SHALL match the sandboxed args. (Judge-related analytics changes land in the judge changes; this one covers the hotkey path.)

## Impact

- Code: `gptel-permit-sandbox.el` (registry defcustoms, resolver, adapter dispatch, latch, hotkey command), `gptel-permit.el` (`gptel-permit--expand-protected-dir` helper, predicate use, default rules docstring), `gptel-permit-analytics.el` (pending-key handling for wrapped args), README (backend registry authoring guide, `./` semantics, latch + reset, `C-c C-s`).
- Hook pipeline: `gptel-permit--apply-rules` unchanged for allow/deny/ask; `sandbox` dispatch moves to registry + adapters. A sandbox rule matching a tool without an adapter now fails closed instead of blindly wrapping `:command`-less calls.
- Dependencies: none on the judge changes; independent of `judge-logging-thinking`. Must be archived after `callable-conditions-and-judge` only if analytics spec deltas interact — they don't (sandbox's analytics concern is self-contained).
