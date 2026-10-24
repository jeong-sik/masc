# Preserve the official blank-Keeper-instructions policy

Repair base: `023234911f71a35e44bfae5411350d05bc609a6d`.

Independent review reproduced a bounded regression: a direct official Host
caller whose hook uses the real request assembler with an empty or whitespace
selected base could pass the existing blank-System guard because the new Goal
suffix made the effective text nonblank. The default production prompt builder
already supplies instructions; this evidence does not establish a default-lane
failure or an outer override bypass.

`Host.prepare_turn` now receives the official runtimes' existing
`composed_context` reader and reads it after hooks. When its issued System text
matches the selected effective System bytes, the private issued `base_text`
must also satisfy the existing nonblank policy. The final effective text still
has to pass that guard. A stale issuer cannot substitute for a different
selected override. The error field and policy remain `system_prompt`; the
change does not infer instructions from Goal text or add a session reset.

All four official runtime callers forward their existing reader. Regular HTTP
assembly, structural `None`/`Some ""` semantics and the stable System suffix
are unchanged. The reader selects the already issued immutable assembly; it
does not reread a Goal store or add another context authority.

`probe_official_blank.py` compiles actual pure request-assembly source, the
exact Safe_ops sanitizer and `trim_nonempty`, and the selected Host selection
and guard statements from both the baseline and repair. Minimal typed ports
stand in for unrelated Host types. Its 19 passing checks reproduce baseline
acceptance and repaired refusal for blank call bases and selected empty or
whitespace overrides; they also check no-Goal identity, a valid selected
override, stale issuer separation and the retained final guard. Hashes,
scope and actual output are in `official-blank-check.json`. This is not an
execution of the full Host hook path or a vendor client.

The authored native Host fixture publishes the production assembly inside the
actual `before_turn_params` hook, so reading the issuer before the hook would
miss the regression. Its negative and positive cases are coupled to real
`Host.prepare_turn`. The parent integration executed the coupled native Host suite atcf60643a1680b6c1cfa678feb5c97034b3bd8d22 in run40103733597:87 Host tests and13 projection tests passed. This is not a live vendor client session. All eight changed OCaml
files parse and `git diff --check` passes; no local Dune or CI watch was used.

The repeatable probe now reads published baselined3a242837194e94c435a228228ac0eaab10724aa; `blank-probe-baseline-binding.json` records byte equality with author baseline0232349.
