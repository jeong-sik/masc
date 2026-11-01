# Selected Claude Keeper inference across catalog reload

PR [#47154](https://github.com/jeong-sik/masc/pull/47154) carries the selected
runtime's typed reasoning effort and model-idle declaration through dispatch,
resume and internal retry. A reload after selection can no longer replace or
remove these values through an ID lookup. Hooks can override or clear effort;
omission and explicit disabled thinking remain distinct. Native Minimal→Low and
Ultra→Max admission and the separate admission timeout retain their behavior.
The old bare HTTP effort clamp remains outside this snapshot unit; #47179
addresses that separate authority defect.

## Actual executions

All are workflow **Test**, ref `fix/claude-selected-inference-20261101`,
`minimal=true`:

| Role | Run | Actual checkout | Actual result |
| --- | --- | --- | --- |
| Parent-production baseline | [41286449774](https://github.com/jeong-sik/masc/actions/runs/41286449774) | `6b8c71081af784c48e84db28aba46d945c15e4c6` | FAILURE: 4 selected PASS / 6 selected FAIL |
| Interrupted first candidate | [41287458749](https://github.com/jeong-sik/masc/actions/runs/41287458749) | `842685433e1142e9458a0f38674a31e283bf8965` | FAILURE: selected alias TIMEOUT after one completed PASS; separate claim-cause 12 PASS |
| Completed selected recheck | [41289637725](https://github.com/jeong-sik/masc/actions/runs/41289637725) | `d2c96d510d21fa393191e10611f66ef92637513c` | SUCCESS: 10 selected PASS / 0 FAIL |

The baseline and completed recheck select
`test_keeper_claude_selected_inference`. The interrupted run additionally selects
`test_official_client_claim_cause`. Its 12 passing cases do not complete the nine
selected-inference cases without completed result rows, and its workflow stays
FAILURE. The completed recheck is a separate execution.

The selected behavior took 28.573 seconds on the baseline and 41.343 seconds on
the completed recheck. The enclosing Dune build/startup plus alias took 447 and
648 seconds. In the interrupted run, behavior started about 592 seconds after
the alias began; the 600-second CI guard stopped the alias at 601 seconds. The
recheck uses the existing `suite_timeout_sec=900` input to accommodate this cold
build plus the selected behavior. Those guard values are recorded separately
from the model-idle declarations exercised by the fixture.

## Observed behavior and comparison

The ten cases cover changed/removed effort, adding effort to a selected absence,
explicit disabled thinking, removing the runtime, selected unbounded idle,
hook override/clear and native Minimal/Ultra admission. The fixture reloads the
catalog in the public driver's `on_runtime_attempt`, after materialization,
and verifies that the live values changed. A controlled HTTP row explicitly
accepts all eight tiers, isolating ID relookup from HTTP catalog clamping.

Each passing case checks actual native argv on a fresh and a resumed process,
the returned marker, and two selected public candidates. The idle case pauses
its child after initialization and receipt of the user frame, distinguishing
the model-idle window from admission. Failed baseline cases can stop at the
first fresh flag check or timeout; they do not establish that later resume or
disabled-thinking assertions were reached.

[case-comparison.json](case-comparison.json) maps actual group/index rows to the
full literal names in each historical source. All ten baseline/recheck keys
match: four PASS remain PASS, six FAIL become PASS, and no PASS regresses. The
interrupted candidate has only one completed selected case row. Ordered keys
use compact UTF-8 JSON `[suite, group, full literal name]` arrays,
`ensure_ascii=false`, comma/colon separators and one trailing LF: SHA-256
`64cdc856f2d684dff06f8ac837315a751d5907256ddcc914857f105e623b75c9`.

The six shared selected fixture functions and the Dune alias file are
byte-identical in all three sources. The complete root test trees differ by
required argument migration in the separate direct-call helper and claim-cause
consumer. [fixture-delta.json](fixture-delta.json) retains the exact two-file
Git diff as original lines with endings; concatenation reproduces its recorded
byte count and digest.

The completed recheck also includes a separate lower Pipeline recovery repair.
[source-comparison.json](source-comparison.json) lists that production delta
instead of claiming whole-production isolation across the negative/positive
pair. The selected official-client branch is reviewed separately from that
Pipeline path. An ancestor's unselected Pipeline test fixture had a public/
internal Agent type mismatch; this native SUCCESS does not certify that
package test or the whole stack.

## Provenance and publication binding

[manifest.json](manifest.json) records actual workflow/ref/head/checkout,
conclusions, separate target counts, CI guard input, raw/retained byte counts
and SHA-256 digests. [baseline.txt](baseline.txt),
[interrupted.txt](interrupted.txt) and [recheck.txt](recheck.txt) retain every
actual timestamped result row, target/checkout receipt, runner summary and
failure assertion. They are ANSI/BOM-normalized derivatives; unselected SKIP
rows and routine build output are omitted and never counted as PASS. Raw
captures remain in ignored `artifacts/issues-oldest-20261101/claude-selected-inference/`.

[source-sha256.json](source-sha256.json) records 20 inputs and four trees at the
actual completed recheck. At the recorded publication parent, all 20 named
inputs and the `lib/`, `test/`, `config/` and `packages/agent_core/lib/` trees are
identical to that recheck. The whole `packages/agent_core/` tree differs only
in the unselected Pipeline test fixture correction. This distinction is
explicit in the comparison; no all-four-tree preservation or current-head
checkout is claimed. Later evidence-only descendants must preserve these
production and target inputs before carrying the execution.

## Limits

The tests use a controlled Claude child with the real adapter/argv protocol.
They do not establish vendor account/model access, the full Claude runtime
suite, full regression, installed runtime, OS restart, integration, deployment,
formal non-author approval or the original catalog hard-cut acceptance. No
local Dune build/typecheck was run. The manifest records the latest observed
prior scheduled Test attempt separately; it is not this candidate's full
regression. No issue is closed.
