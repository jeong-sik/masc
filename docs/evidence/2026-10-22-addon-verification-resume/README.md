# Addon verification resume · 2026-10-22 KST

## Original failure and existing repair

Frozen product `e6c7521a0b709de79ed8997d204cd5924f395dbb` was requested through
workflow source `b2397d64a01f8f1606ca464f7d64ac48f029e306` in
[native run 39620100070](https://github.com/jeong-sik/masc/actions/runs/39620100070).
The completed run failed before behavioral suites or a qualified binary receipt.
`failed-native-run.json` is the original terminal API observation;
`failed-native-compiler-excerpt.txt` preserves the original timestamped error lines.
The two errors are record inference failures in
`keeper_tool_execution_journal.ml` (`immutable_source`) and
`keeper_composition_named_submission.ml` (`parent_tool_use_id`).
The six Security.framework deprecation warnings did not cause this failure.

[PR #44864](https://github.com/jeong-sik/masc/pull/44864) subsequently supplied
explicit journal/source types and fixture repairs after the frozen e6 source
was selected. It merged at 14:50:18 UTC, before the already-running frozen
check finished at 14:55:58 UTC; that run did not acquire the new source. It merged as
`9e5fc114adc00c8a12878b55ee9c1523df86e6c7`; `pr-44864-merged.json` records
its actual state. The current source contains that repair. We reuse it rather
than writing another repair. Source inspection does not prove a successful build.

## G06 integration and correction

`g06-merged-prs.json` records all six G06 PRs (#44838, #44839, #44843,
#44852, #44868, #44869), their actual merged heads, timestamps and squash
commits. They landed at 2026-10-21 15:01:05–11 UTC (2026-10-22 KST).
This session did not submit that merge operation.

Correction: REST returning the older heads for the last two PRs was initially
assumed to be propagation delay. They were already merged at those heads.
The subsequently pushed `f1d6ce14`/`04bc60bf` branches only added the missing
self-PR citations to the last two changelog fragments; those later branch heads
are not the merged PR heads. This follow-up applies the two citations on a new
branch. No follow-up is pushed to a closed G06 PR.

## New selected source

Current main `4d25f9e175120740de2a0c254693c4bd73fbd534` contains both the
empty-query `/slice` fix from #44868 and the #44864 compilation repair.
Compared with G06's merged top `80b7c0b4`, its only changes are the two
subsequently merged glossary documentation PRs #44866 and #44870.
The native `addon-lifecycle` request is recorded in `native-dispatch.json`.
It selects the existing two suites and matching server/TUI/key generator.
Dispatch acceptance is not successful compilation, artifact qualification or
visible UI. At this publication boundary its result has not been read.

The [frozen d9 actual observations](../2026-10-21-addon-slice-scope/README.md)
remain tied to d9 and its failed `/slice?` observation. They are not execution
proof for this main source. The historical repaired-native evidence stack
#44851 and the 67-layer Browser stack #44168 are still open in this resume
snapshot. No operator process, profile, credentials or installation was changed.
The original 54 item names and completion criteria remain unchanged.

## Later publication boundary: 4d25 failed; existing TUI repairs reused

The first result read for run39623698078 found completed failure. The original
terminal API observation and timestamped compiler errors are retained as
`main-4d25-native-failed.json` and `main-4d25-compiler-excerpt.txt`.
The failures are three warning4 diagnostics: observation and receipt variants
in `recorded_task`, and `ask_asker` in `open_ask_task_inspection`.
The earlier Keeper errors did not recur in this log; this is still not a
successful matching binary or behavior receipt.

Two existing repairs independently landed while this work continued:
#44874 at15:23:09Z (`e4c8e3f3`) and #44875 at15:23:10Z (`003f52e2`).
Their merged states are preserved. Both modified functions were read directly
at003f52. A separate approved alternative #44873 passed merge-guard but its
actual merge request was rejected by GitHub as dirty after those repairs
landed. It remains unmerged; no merge success is claimed and no duplicate
repair was added. No `--auto` or `--admin` was used.

`main-003f-native-dispatch.json` records the new addon-lifecycle request for
exact source003f52. This new candidate includes the concrete compiler repairs;
its result is not yet read. The existing two suites still do not cover the
actual HTTP empty-query assembly or replace a manual corrected global Slice
observation. Historical successful d9 proof is not execution of003f52.

`browser-integration-census-summary.json` preserves the independent67-layer
identity census and the queued whole-stack rebase request. A source-bound
approval count is not a whole-stack source-review or merge verdict. The latest
main moved after that census, and any rebase requires fresh identity checks.
