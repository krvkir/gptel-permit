# sandbox-extension Delta

## ADDED Requirements

### Requirement: Backend registry
The sandbox SHALL dispatch all sandbox wrapping through
`gptel-permit-sandbox-backends`: an alist mapping a backend symbol to a
plist `(:available-p FN :wrap FN)`, where `:wrap (command root) → wrapped
string`. The shipped registry SHALL contain `bwrap` and `srt` entries; users
MAY add their own entries (e.g. via `add-to-list` or customize) and MAY
replace shipped entries. An unknown backend symbol SHALL fail closed with
`(:confirm t)` and a log line naming the symbol. Registry entries are
security-relevant: `:wrap` output runs with `:confirm nil`, so a broken
wrapper effectively disables sandboxing — the contract SHALL be documented
as such in the defcustom docstring.

#### Scenario: Custom backend participates
- GIVEN a user adds `my-sandbox → (:available-p (lambda () (executable-find "nsjail")) :wrap #'my-wrap)` to the registry and sets `gptel-permit-sandbox-backend` to `my-sandbox`
- WHEN a sandbox rule matches a Bash call
- THEN the command is wrapped via `my-wrap` and auto-run when `my-wrap` returns a string.

#### Scenario: Unknown backend fails closed
- GIVEN `gptel-permit-sandbox-backend` is `docker-sandbox` (not in the registry)
- WHEN a sandbox rule matches
- THEN the hook returns `(:confirm t)` and the log names the unknown backend.

### Requirement: auto resolution
When `gptel-permit-sandbox-backend` is `auto`, the sandbox SHALL resolve the
backend once per session via `gptel-permit--sandbox-resolve-backend`: on
GNU/Linux resolve to `bwrap`; on other platforms resolve to the first
registered backend (registration order) whose `:available-p` returns
non-nil; resolve to nil when none is available. Resolution SHALL consider
user-registered backends, so a third-party backend becomes reachable via
`auto` without code changes. Availability SHALL be re-verified at wrap time
per call (memoization affects only the choice, not safety). The resolved
value SHALL be reported in the log.

#### Scenario: Linux resolves to bwrap
- GIVEN `system-type` is `gnu/linux` and bwrap is on exec-path
- WHEN the backend is resolved for the first time
- THEN `auto` resolves to `bwrap`.

#### Scenario: Non-Linux picks first available registered backend
- GIVEN `system-type` is `darwin`, `srt` is not installed, and a
  user-registered backend `mac-sandbox` whose `:available-p` returns t
- WHEN the backend is resolved
- THEN `auto` resolves to `mac-sandbox`.

#### Scenario: Nothing available resolves to nil
- GIVEN `system-type` is `windows-nt` and no registered backend is available
- WHEN the backend is resolved
- THEN `auto` resolves to nil and every sandbox action fails closed.

### Requirement: Tool adapter registry
The sandbox SHALL rewrite tool-call arguments through
`gptel-permit-sandbox-adapters`: an alist mapping a tool name (string) to
`(:wrap-args (args root) → new-args)`. The shipped registry SHALL contain a
"Bash" adapter wrapping `:command` via the resolved backend. Adapters
rewrite arguments only — they SHALL NOT execute anything. The adapter
contract SHALL support whole-call mechanics (e.g. a future "Eval" adapter
spawning a sandboxed Emacs for the expression), which is why the contract
is args-in/args-out rather than string-in/string-out. A tool call matching
a sandbox rule with no registered adapter SHALL fail closed with
`(:confirm t)` and a message naming the tool.

#### Scenario: Bash adapter wraps command
- GIVEN the shipped "Bash" adapter and backend bwrap
- WHEN a Bash call with `:command "cargo test"` is sandboxed
- THEN the returned args carry a `:command` equal to the bwrap-wrapped string.

#### Scenario: Eval adapter is a registry entry, not core code
- GIVEN a future user-added "Eval" adapter entry
- WHEN an Eval call matches a sandbox rule
- THEN the sandbox core rewrites the call purely via the registry — no
  sandbox-core change is needed to support the new tool.
