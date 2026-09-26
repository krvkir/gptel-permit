## Why

The judge is currently only usable as a sync condition: the whole interface
freezes in `accept-process-output` for the judge's latency (seconds). The
primary goal of asynchronous judging is to keep *other* buffers — the rest
of Emacs — fully usable while the judge thinks; keeping the session buffer
itself free of a prompt during the wait is a nice-to-have, not a
requirement. Making the judge an *action* gives a clean async shape with
**zero changes to gptel**: the hook returns `(:confirm t)` immediately, the
pending-confirmation UI appears, and a judge callback applies the verdict's
resolution when it lands. The prompt-while-judging tradeoff (visible confirm
that auto-vanishes on SAFE) is accepted for now; the optional
`judge-async-defer` change (a small gptel patch) can later remove the
prompt flash if it proves annoying in practice.

## What Changes

- New judge action forms for the `:action` rule slot, covering both
  verdicts:
  - bare `judge` ≡ `(judge allow ask)` — accept on SAFE, ask on UNSAFE;
  - `(judge ACTION)` — apply ACTION on SAFE, ask on UNSAFE (e.g.
    `(judge sandbox)`);
  - `(judge ON-SAFE ON-UNSAFE)` — different actions per verdict (e.g.
    `(judge sandbox deny)`; `(judge allow sandbox)` runs a SAFE call
    directly but sandboxes an UNSAFE one).
  ON-SAFE/ON-UNSAFE SHALL be any existing action: `allow`, `deny`, `ask`,
  `sandbox`. Malformed forms log a warning and act as `ask` (fail-closed).
- Judge-as-action semantics: the judge sits in the action slot, so it does
  NOT determine rule applicability. The rule matches on its conditions
  exactly like any other rule (first-match-wins; no fall-through to later
  rules on UNSAFE — that is the condition form's job). The judge determines
  the *resolution* of the matched rule: SAFE → ON-SAFE, UNSAFE → ON-UNSAFE,
  judge failure (timeout, unparseable, failed request) → manual
  confirmation. A `deny` resolution's block reason SHALL include the
  judge's rationale.
- `gptel-permit-judge-async` defcustom (default `t`): async mode as
  described; `nil` evaluates the judge action synchronously (blocking,
  identical verdict mapping). The existing *condition* form
  (`gptel-permit-judge-safe-p` in `:conditions`) remains unchanged and
  synchronous.
- Async flow: the hook fires a non-blocking judge request and returns
  `(:confirm t)` immediately; a watchdog bounded by
  `gptel-permit-judge-timeout` resolves the pending call as failed if no
  response arrives.
- Callback resolution: the verdict's ON-SAFE/ON-UNSAFE action is applied to
  the pending-confirmation pack — programmatically only when every pending
  call in the pack is judge-gated and all resolutions are uniform:
  all accept-class (allow, sandbox with args rewritten through the
  action-registry sandbox handler) → the pack is accepted; all `deny` → the pack is
  rejected with the judge rationales fed back to the model. Any mixture,
  any `ask` resolution, any non-judged call, or audit-sampled call → the
  prompt stays for the human (fail-closed by inaction).
- Judging indicator: while a judge verdict is pending, the tool-call prompt
  displays a "judging…" indicator, removed when the pack resolves or the
  user answers.
- Race guards: the callback no-ops when the buffer is dead, the overlay is
  gone, or the stashed call already has a result (the user acted first —
  their decision wins).
- Analytics: a `judge-verdict` event records the verdict/rationale when it
  lands (correlated with the tool-call id); programmatic resolutions are
  recorded as `decision` events with `auto-allow`/`deny` choices distinct
  from user decisions; audit sampling extends to judge-gated calls — the
  judge still runs and is logged, but the resolution is forced to a manual
  confirmation whatever the verdict.

## Capabilities

### Modified Capabilities
- `llm-judge`: the judge action forms (grammar and verdict semantics),
  async request mode, prompt-mode resolution semantics, pack gating, the
  judging indicator, and the sync mode. The condition form is untouched.
- `rule-engine`: the `:action` slot grammar gains the judge forms
  (`judge`, `(judge A)`, `(judge A B)`).
- `analytics`: `judge-verdict` event type; `auto-allow`/`deny` programmatic
  decision choices; sampling suppression of programmatic judge resolutions;
  serialization of list-form judge actions in rule-match/verdict events.

## Impact

- Code: `gptel-permit-judge.el` (async request path, callback resolution,
  watchdog, indicator, and the `judge` action handler registered in
  `gptel-permit-action-handlers`), `gptel-permit.el` (list-form action
  dispatch only — a cons action looks up its car in the action registry;
  no judge knowledge in the core), `gptel-permit-analytics.el`
  (judge-verdict events, programmatic decision choices, sampling
  suppression, action serialization), README.
- Hook pipeline: `gptel-pre-tool-call-functions` contract unchanged —
  async mode just returns `(:confirm t)`; all gptel interaction happens via
  the documented pending-confirmation overlay (`gptel--accept-tool-calls`
  with possibly-edited triples; a deny resolution feeds each pending call's
  result callback with the block reason and cleans up, mirroring gptel's
  steer path).
- Dependencies: builds on `judge-logging-thinking` (failure classes,
  `gptel-permit-judge-request-params`), `decoupling` (the action registry:
  the judge action is a handler with the `(ID TOOL-CALL)` signature, and
  audit sampling rides the engine's veto hook), and
  `sandbox-backend-registry` (the sandbox *tool-adapter* registry for
  `(judge … sandbox)` resolutions, wrapped inside the sandbox action
  handler); must be implemented after all three. The optional
  `judge-async-defer` change later adds a prompt-free parking mode without
  changing the rule DSL.
