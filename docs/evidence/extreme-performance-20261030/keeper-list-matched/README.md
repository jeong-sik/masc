# Unsampled native Keeper-list pair

The 100 us objective remains unmet. This bundle contains one owned native run per
source at 2, 30 and 300 held server owners, using the same list-only observer.
All six workloads completed their original 4/60/600 operations with validated
replies and offline durable-store rereads. The 300-owner candidate has lower
observed list Build quantiles, while the 30-owner candidate has a higher p95.
These six runs do not establish a stable or causal product speedup.

## Executed sources and build boundary

Control source is `5297349b101d61bb901b3729d43c4dec8bb30ec4`; candidate source is
`5de2eb7684f0e4fecee1c48caef50010c2f951fa` (PR #46941). Native receipts and the
corrected information-command verification are under [native/](native/).
Candidate **Minimal manual checks**, run
[41025395547](https://github.com/jeong-sik/masc/actions/runs/41025395547), completed
successfully: wrapper head `06e43272be3f4bec7d2798f7d8d464774536895c`, ref `main`,
requested native source `5de2eb7684f0e4fecee1c48caef50010c2f951fa`, scenario
`workspace-files`. Its three executed suites are `test_repo_git`,
`test_tui_workspace_entries`, and `test_workspace_file_confidentiality`, all exit
zero. They are accompanying file checks, not Keeper-list behavior or full
regression proof. Both downloaded executable hashes and embedded source commits
were checked before this matrix.

An earlier information check mistakenly passed `--build-commit` to the server;
the server requires `build-commit`, while the TUI uses `--build-commit`. The
separately self-checking initial two-owner probe ran before the corrected
readback, so the later check does not retroactively gate that earlier probe.
That probe is outside this matrix. The retained corrected receipt says so.

## Observation

The executed controller is [v1/run.py](keeper-list-matched-v1/run.py), not v2.
Order: 2 control, 2 candidate, 30 candidate, 30 control, 300 control, 300 candidate.
Each arm owns its base, HOME, server, loopback scripted provider and native TUI.
The checkout remained `227de7fbd64d9925590f4725bc100806e5d0bf82` throughout.
No OS stack sampler was attached. One complete `3` byte write requests Keepers;
the window ends eight seconds after the first paired DEC2026 transport block,
not eight seconds after key application. There is no key-application receipt.

| Held owners | Variant | List Builds | Build p50 ms | Build p95 ms | Build max ms | Whole TUI CPU s |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 2 | control | 61 | 0.210 | 0.527 | 1.638 | 0.342385 |
| 2 | candidate | 63 | 0.205 | 0.418 | 1.079 | 0.369540 |
| 30 | control | 71 | 0.608 | 1.246 | 1.486 | 0.469884 |
| 30 | candidate | 62 | 0.560 | 1.775 | 3.568 | 0.471712 |
| 300 | control | 95 | 4.256 | 7.670 | 9.837 | 1.733041 |
| 300 | candidate | 88 | 3.533 | 4.570 | 7.485 | 1.402502 |

[analysis-v6.json](keeper-list-matched-v2/analysis-v6.json) retains exact raw
integer nanoseconds. Quantiles use sorted index `int(q*(n-1)+0.5)`. An initial
interactive calculation used nearest-rank and reported the 300 control p95 as
8.292 ms; the consistent definition above gives 7.670 ms. Native raw elapsed
records are unchanged. All-Present distributions are recorded separately; they
span overview and list frames and do not measure physical paint.

Population is actual concurrent held provider/owner work, not instrumented
UI-loaded row count. List Build tags do not certify all N Keepers were applied.
This captures neither deep scroll/Page Down nor DAW interaction. Native
process-relative Mtime timestamps are not joined to Python perf-counter origins.
There is one arm per condition, differing frame counts and uncontrolled shared
host load. CPU count and load averages before/after each arm remain in the
execution/analysis records; load differs substantially between the 300 arms.

The candidate also contains the stage interval-union diagnostic repair and DAW
source changes relative to control. Raw Build elapsed recording is unchanged,
but exit-report work and residual definitions differ. Do not compare old/new
`unattributed` directly or attribute whole-process CPU changes solely to row
reuse. These are whole native binaries built by different wrapper heads and
scenarios. No allocation or independent per-stage causal counterfactual is
established by this pair.

The server remains a separate unresolved latency boundary. In the released-model
phase, control/candidate health maxima are 14,127.573/9,563.735 ms and p95 values
74.047/29.031 ms. HTTP 429 counts are 40/49, with 40.141/49.171 seconds of recorded
client fallback wait. Both runs completed 600 original operations, but their
workload durations and health tails are not a server optimization result: server
library source is unchanged between these two native sources. The earlier
[sampled 300-owner failure](../keeper-list-sampling/README.md) is preserved and
is not replaced by these unsampled successful runs.

## Retrospective qualification and prospective repair

V1 did not gate each 30/300 transition on cleanup, and its final success condition
omitted source equality at those populations. That is an execution-controller
defect. The [analysis](keeper-list-matched-v2/analysis-v6.json) therefore separately
qualifies every arm and all preceding arm safety records after execution. All
six have matching source/digests, complete native phase records and direct owned
cleanup: server exit zero/reaped, no forced kill, HTTP sampler/model server
stopped, provider requests drained with zero active requests/handler threads.
Before/after runtime instance and base, owned PID, and the original execution
output are bound to the same arm. No failure/fallback receipts occur in these
six successful arms. This is not a prospective gate, global host quiescence or
proof that every descendant ceased.

[V2](keeper-list-matched-v2/run.py) is a prospective reproduction controller. It
checks the actual runner-directory modules and repo-relative fixture before a
child, then gates the next child on complete cleanup and identity. Two-owner
qualification failure prevents expansion. A later nonzero workload may continue
only with matching main/failure/fallback cleanup evidence; the final result stays
failed. Missing or contradictory receipts stop the plan. The current timing
bytes are reparsed with the pinned frozen observer, checking raw counts,
ordinals and omissions against their recorded summaries. There was no independent
capture-time timing-file hash in v1; this does not recover historical byte
identity. It binds the bytes read during retrospective qualification/retention.

The one-off [boundary validation](keeper-list-matched-v2/boundary-validation-v6.json)
passed 27 resource/identity cases, including actual child-fixture checks that bad
cleanup prevents the next child, clean failure continues but fails the matrix,
and two-owner failure prevents expansion. It exercises no server/TUI and makes
no screen text/layout/order assertions. Assertions were enabled. Independent
adversarial and response source reviews are separate from formal GitHub approval.
V2 did not execute the six native arms recorded by v1.

## Retention and reproduction

[provenance.json](provenance.json) pins 120 exact selected source/capture pairs,
including executed v1, frozen probe copies, native receipts, raw timings,
observations, admitted synthetic operations, terminal replies and selected
post-shutdown SQLite exports. Digests reflect the later qualification/retention
read, not an invented capture-time manifest. Complete binaries, raw terminal
streams, auth/config files, full SQLite/WAL and provider/request logs remain in
ignored `artifacts/`. Eighteen owned credential values were checked privately
against the selected files with zero matches; no credentials are retained.

For a new run, copy the prospective helper/probe files into a new ignored working
directory and supply a config with the exact native paths/digests, actual probe
runner and fixture checkout. `config-v2.json` preserves original local paths;
adjusting paths is a new invocation, not a change to retained captures. Run
`run.py --config NEW_CONFIG --output NEW_IGNORED_OUTPUT` with Python 3.11+ and the
matching macOS native dependencies. Never rerun output-writing helpers over this
bundle. The retained analyzer explicitly targets the completed v1 matrix, not
arbitrary failed future matrices. The shared installation/runtime was not
installed or restarted by these experiments.
