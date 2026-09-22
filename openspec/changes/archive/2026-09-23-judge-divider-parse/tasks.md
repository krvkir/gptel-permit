# Tasks

## 1. Parser and logging
- [x] 1.1 Rewrite `gptel-permit--judge-parse-verdict` as the divider:
      first standalone SAFE/UNSAFE line splits thinking from
      rationale; conflict rule kept; line-exact matching kept.
- [x] 1.2 Delete `gptel-permit--judge-strip-thinking` and remove
      stripping from every docstring.
- [x] 1.3 Store and log the full raw response on parse-fail (drop the
      `gptel-permit--truncate-arg` bound).

## 2. Tests and docs
- [x] 2.1 Tests: divider drops thinking above; duplicate same-word
      divider keeps below-text; reasoning markers are ordinary text;
      draft conflict fail-closes both ways; parse-fail rationale
      untruncated; strip tests removed.
- [x] 2.2 Docstrings: parse-verdict, judge-evaluate,
      `gptel-permit--last-judge-rationale`, request-params cloud
      caveat.
- [x] 2.3 README: parsing paragraph, unparseable log-line entry.
- [x] 2.4 `make test` green (also fixed a pre-existing flake in
      `gptel-permit-analytics-ids-continue-after-existing-file` —
      unseeded `random` vs sample-rate 0.2 — by stubbing `random`);
      byte-compile clean; openspec strict validation passes.
