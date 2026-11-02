# Atomic catalog publication execution

Source PR [#47397](https://github.com/jeong-sik/masc/pull/47397) replaces the
two individually mutable catalog sources with one admitted immutable value.

Initial **Test** [41329452881](https://github.com/jeong-sik/masc/actions/runs/41329452881),
checkout `1546b54953269fedb15d7e6d8f1a02c344585219`: **FAILURE, 980 PASS / 1 FAIL,
3 SKIP** across 18 explicit suites. The nested provider/model fixture erased
its outer JSON overlay, so its exact tuple assertion could not find the binding.
All 24 snapshot cases and 132 bootstrap cases passed inside that failed workflow.
Bootstrap cases 115,116,118 attempted subprocess startup and ended SKIP before
terminal health/dashboard assertions. They are neither passes nor completed
startup proof.

Corrected **Test** [41359944826](https://github.com/jeong-sik/masc/actions/runs/41359944826),
checkout `e3d6f3bef78da14a0a89e1faca6929cd3f1dc5d3`: **SUCCESS, 1082 PASS / 0 FAIL, 3 SKIP** across
the original 18 suites plus per-keeper routing. Both dispatches explicitly use
minimal=true and the existing 600-second per-suite guard. Counts are separate
executions, not a sum or a same-fixture production reproduction. The fixture
helpers now compose their complete captured parent pair and restore that whole
value; original behavioral assertions remain. Production is unchanged between
the two runs: 19 identical existing inputs and two absent façade paths.

`manifest.json` keeps checkout, dispatch, per-suite counts, distinct raw/selected
digests and unique emitted case identities. `initial.txt` preserves the three
SKIP lines in a supplemental selection; `initial-original-selection.txt` and
its separate receipt preserve the original selection bytes and digest.
Display/group text may be ellipsized. Hashes
identify exact fixture bytes; skipped cases are never promoted to passes.

Each per-phase case-key digest uses that phase's `cases.tsv` rows in retained
case-emission order. Serialize an array of `[source, emitted_group, index,
source_sha256]` arrays with index as a JSON integer, UTF-8, ensure_ascii=false
and compact comma/colon separators, then append exactly one LF byte before
SHA-256. Phase, status and display text are excluded from this per-phase hash;
phase still distinguishes rows in the combined table.

Each expanded source manifest binds 108 named inputs and four complete trees at
its own executed head. Three named fixture inputs differ; Core/test trees also
differ, while lib/config trees match. Corrected inputs and all four corrected
trees match the evidence parent; later evidence-only heads are not newly
executed. `original-corrected-source.json` preserves the initial 30-input capture;
the expanded 108-input derivative adds complete unit paths at the same e3 head
and explains that derivation rather than relabeling the original capture.

Native/batch negative controls now reject invalid input before publication and
check retained typed outcomes; opaque publication cannot install the former
invalid global state. No invalid-current forcing proof is claimed. No local
build/typecheck, full regression, real-provider/account, installed runtime,
OS restart, formal nonauthor approval or whole-stack integration is claimed.
The original strict/high-level/startup/account/native requirements of #27898
remain open. Historical profile461, Batch298 and Media146 are separate runs.
