## Why

Live testing of the LLM judge with an Ollama cloud model
(`glm-5.3-flash:cloud`) exposed two response-side failure modes that
verdict parsing could not handle:

1. The model ignored the derived `:think :json-false` request
   parameter, interleaved its reasoning with the answer, and — in the
   observed case — glued its closing think tag directly between the
   prose and the verdict on a single line, leaving no standalone
   verdict line anywhere. The call parse-failed and fell through.
2. The user's observed history: the same model answered /without/
   reasoning text before the thinking-suppression parameters were
   sent, and started writing reasoning into the answer once they
   were. The request-side attempts can make things worse.

## What Changes

- New `gptel-permit-judge-control-thinking` defcustom (default `t`).
  When nil, no thinking-related request parameters are derived or
  injected at all; explicitly-set `gptel-permit-judge-request-params`
  are still sent verbatim.
- New closing-tag heuristic in verdict parsing:
  `gptel-permit--judge-drop-thinking` drops everything up to and
  including the LAST closing reasoning tag (think/thinking variants,
  case-insensitive) before the divider rules apply. A verdict word
  drafted as a standalone line inside a closed block resolves
  instead of conflicting; an unclosed block provides no trustworthy
  boundary and the response is left whole.
- The conflict rule (standalone SAFE and UNSAFE lines both present)
  applies to the post-truncation text only.
- The matching regexp and tests are built from character classes and
  string fragments so no literal tag bytes live in the source tree
  (the development toolchain has been observed to corrupt literal
  tag bytes in written files).

## Impact

- `gptel-permit-judge.el`: new defcustom, new defconst + helper
  function, parser pipeline (heuristic then divider), docstrings.
- `tests/gptel-permit-judge-test.el`: rewrite of the pseudo-marker
  tests to real (fragment-built) tags, new gate/drop/parse tests.
- `README.org`: judge sections document the switch and the heuristic.

Archive order: `judge-divider-parse` must archive before this change;
`judge-schema-verdict` depends on both.
