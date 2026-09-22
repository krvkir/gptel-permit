## 1. Request-side switch

- [x] 1.1 Add `gptel-permit-judge-control-thinking` defcustom
      (boolean, default `t`) to `gptel-permit-judge.el`.
- [x] 1.2 Gate the derivation: `gptel-permit--judge-request-sync`
      derives thinking-off params only while the switch is non-nil;
      explicit request params still go through verbatim.
- [x] 1.3 Update the `gptel-permit-judge-request-params` docstring
      cross-reference.

## 2. Response-side closing-tag heuristic

- [x] 2.1 Add `gptel-permit--judge-think-close-re` (character-class
      regexp; no literal tag bytes in source).
- [x] 2.2 Add `gptel-permit--judge-drop-thinking`: drop through the
      last closing tag; unclosed responses pass through unchanged.
- [x] 2.3 Apply the heuristic first in
      `gptel-permit--judge-parse-verdict`; divider and conflict rules
      apply to the remaining text.

## 3. Tests and documentation

- [x] 3.1 Gate test: switch nil sends nothing derived; non-nil
      restores the derived default; explicit params are verbatim.
- [x] 3.2 Drop tests: last-closing-tag wins, thinking/thinking
      variants, unclosed unchanged.
- [x] 3.3 Parse tests: the observed glued-closing-tag shape parses
      safe; drafts inside closed blocks resolve; unclosed drafts
      still fail closed.
- [x] 3.4 README: switch paragraph, cloud-model paragraph, two-step
      verdict parsing description.
- [x] 3.5 Byte-compile clean; full suite green (137 tests).
