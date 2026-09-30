## Why

The sandbox's rough edges from first use: `auto` is a misleading alias for the builtin wrapper (spec and docstring even disagree about what it resolves to), `builtin` hides that the backend is bubblewrap, and macOS/Windows get no sandboxing at all instead of degrading sensibly. The protected-path list is duplicated between `gptel-permit-protected-dirs` and hardcoded sandbox entries, the failure-streak auto-resets with no way to reset it deliberately, and there is no interactive escape hatch to run a command inside the sandbox on demand. The mechanism is also welded to Bash-only rewriting with no extension point for the next tool (Eval needs entirely different sandbox mechanics), and the two shipped backends live inline in one file with no clear contract between "the sandbox engine" and "a sandbox backend".

## What Changes

- **BREAKING**: rename backend symbol `'builtin` → `'bwrap` (`gptel-permit-sandbox-backend` values become `auto`/`bwrap`/`srt`).
- `auto` becomes a real resolver: a static platform table — on Linux it
  resolves to `bwrap`; on macOS/Windows it resolves to `srt`; on any other
  platform it resolves to nil. There is no cross-fallback and no
  registry-order scan: if the table-selected backend's binary is missing,
  `auto` resolves to nil and the sandbox action fails closed
  `(:confirm t)` with a logged reason naming the backend. `auto` is
  re-resolved on every call (no memoization), so a binary installed later
  is picked up without a restart. Users who want a different backend set
  `gptel-permit-sandbox-backend` explicitly; everything dispatches through
  the registry either way.
- Pluggable backend registry with a CLOS backend contract: `gptel-permit-sandbox-backends` maps a backend symbol to an EIEIO class; the contract is two generic functions — `gptel-permit-sandbox-available-p (backend)` and `gptel-permit-sandbox-wrap (backend command root)`. Third parties subclass `gptel-permit-sandbox-backend`, define methods for both generics, and register their class symbol. The sandbox action, hotkey, and `auto` resolver all dispatch through the registry.
- The stock backends move into their own modules: `gptel-permit-sandbox-bwrap.el` and `gptel-permit-sandbox-srt.el`, each defining its class, its generic methods, and contributing its registry entry at load. The sandbox core requires neither at load time: a constant feature table maps backend symbol → feature name, and resolution/dispatch lazily requires the module on first use, so stock backends load only if a sandboxed call needs them. The core contains no backend-specific wrapper construction. Backend classes are stateless; dispatch instantiates (and caches) one instance per class.
- Tool adapter registry `gptel-permit-sandbox-adapters`: alist `"TOOL-NAME" → (:wrap-args FN)` where the adapter rewrites a tool call's args plist into sandboxed args. Ships with a `"Bash"` adapter (wraps `:command` via the resolved backend); a call for a tool without an adapter fails closed `(:confirm t)` with a message — this is the extension point where the future `Eval` adapter (sandboxed Emacs subprocess running the expression) will land, without touching the sandbox core. Adapters stay function-valued (single-function contract); the asymmetry with CLOS backends is deliberate.
- Single source of truth for protected paths: `gptel-permit-protected-dirs` gains `./.git` in its default value and supports a `./` prefix meaning "relative to the project root" (new shared helper `gptel-permit--expand-protected-dir`, used by both the `:inside-protected-dirs` predicate and the sandbox). The sandbox drops its hardcoded `ROOT/.git`, `~/.ssh`, `~/.gnupg` entries and derives all protected paths from the option (plus its rc-files constant). **BREAKING** for users who customized `gptel-permit-protected-dirs` (defaults change; per project reality there are no such users yet).
- Failure streak becomes a sticky latch: when `gptel-permit-sandbox-retry-limit` consecutive sandboxed failures are hit, the buffer stays latched (every sandbox verdict = `(:confirm t)`) until a sandboxed command succeeds or the user runs the new `M-x gptel-permit-sandbox-reset`. No more silent auto-reset on trip. `gptel-permit-sandbox--remember`'s docstring explains its result-attribution purpose.
- Interactive sandboxing: `C-c C-s` (`gptel-permit-accept-tool-calls-sandboxed`) in `gptel-tool-call-actions-map` rewrites the pending tool calls through the adapter registry and accepts them — all-or-nothing: any adapterless tool in the pack refuses the whole acceptance with a message (plain `C-c C-c` remains available for unwrapped acceptance).

## Capabilities

### Modified Capabilities
- `sandbox`: backend naming (`bwrap`), the CLOS backend registry and its contract, the `auto` resolution semantics, stock backend modules, the tool adapter registry, protected-path sourcing from `gptel-permit-protected-dirs` (no hardcoded list), the sticky failure latch with explicit reset, and `C-c C-s`.
- `rule-engine`: `:inside-protected-dirs` gains project-root-relative `./` semantics shared with the sandbox; `gptel-permit-protected-dirs` default gains `./.git`.
- `analytics`: the pending-confirmation key must not orphan when args are rewritten between confirm and accept (hotkey/judge-sandbox paths); the decision event SHALL match the sandboxed args. (Judge-related analytics changes land in the judge changes; this one covers the hotkey path.)

## Impact

- Code: new `gptel-permit-sandbox-bwrap.el` and `gptel-permit-sandbox-srt.el` (extracted classes/methods), `gptel-permit-sandbox.el` (registry defcustoms, resolver, adapter dispatch, latch, hotkey command — minus all backend-specific wrapping), `gptel-permit.el` (`gptel-permit--expand-protected-dir` helper, predicate use, default rules docstring), `gptel-permit-analytics.el` (pending-key handling for wrapped args), README (backend authoring guide with the CLOS contract, `./` semantics, latch + reset, `C-c C-s`), AGENTS.org project-structure list (new files).
- Hook pipeline: `gptel-permit--apply-rules` unchanged for allow/deny/ask; `sandbox` dispatch moves to registry + adapters. A sandbox rule matching a tool without an adapter now fails closed instead of blindly wrapping `:command`-less calls.
- Dependencies: none on the judge changes; independent of `judge-logging-thinking`.
