# Native prepared-roster observations

The prepared roster candidate builds and its targeted Keeper-control suite
passes. A new six-arm native experiment has five eligible arms and one failed
observation. The matrix result is **false**. The 100 us goal remains open.

## Source, build and workload

The control is source `5de2eb7684f0e4fecee1c48caef50010c2f951fa`; the prepared
roster candidate is `c275c5e18bdf0977ec3cfdd33e16bd65d3367236` from PR #46980.
The source delta in `lib/`, the native build workflow/actions and release
fixture directory is empty between these heads. Whole binaries and build
wrapper revisions differ; dependency/toolchain equivalence is not established.

[Minimal manual checks 41041914326](https://github.com/jeong-sik/masc/actions/runs/41041914326)
completed with conclusion **success**. Its wrapper ref is main, execution head
`50011c4550cb49153c189586f60bee6438b2f232`; the requested and packaged native
source is the candidate above. Its `workspace-files` scenario runs
`test_repo_git`, `test_tui_workspace_entries` and
`test_workspace_file_confidentiality`, all exit 0. Local readback of the downloaded
server's `build-commit` and TUI's `--build-commit` confirms candidate source and
the [artifact receipt](build/native/receipt.json) digests:

- Server: `71eeee4314600f1431d587b5ae2377a707aa5230f4930cd418435ef6046b59cc`
- TUI: `56c907eff3ddc752f73160414ea3d1799a68688394a710a2f849ed7c0adc22de`

[Test 41041918389](https://github.com/jeong-sik/masc/actions/runs/41041918389)
completed with conclusion **success** at candidate head/ref
`perf/tui-roster-prepared-reading-20261030` with
`TARGET_SUITES=test_tui_keeper_control`: **61/61**, including the three added
lifecycle tests. The [suite log](build/control-suite/ci-run-tests.log) is
retained. The edited server-identity test fixture was not selected; this is
not full regression. The control native artifact uses wrapper
`06e43272be3f4bec7d2798f7d8d464774536895c` and has its separate
[receipt](build/control-native-receipt.json).

Each native arm owns a separate server, base path, ports and TUI process. Two
messages per Keeper use a loopback scripted text-only provider. Real held
provider requests establish the 2/30/300 owner populations. The order is
2 control, 2 candidate, 30 candidate, 30 control, 300 control, 300 candidate.
Five successful arms verify 4/4, 60/60 or 600/600 durable operations and replies.
This is an admin-submitted workload, not peer broadcast, external provider,
guest execution or production throughput evidence. The shared runtime was
not restarted or loaded by these experiments; the binaries were not installed.

The unsampled observer writes `3` once and collects for eight seconds from
the first paired DEC 2026 ready marker. That marker does not acknowledge key
application or the number of applied UI rows. No new screen/layout assertion
is introduced. Build reports measure native computation; terminal paint and
physical flicker remain unobserved.

## Valid comparisons and failed observation

The table uses exact raw nanosecond values, converted to ms. Quantiles select
sorted index `int(q*(n-1)+0.5)`. There is one native arm per population/source;
these are within-arm frame cohorts on an uncontrolled shared host. They do
not establish a causal or stable fleet speedup.

| Held owners | Source | List Build samples | p50 ms | p95 ms | Maximum ms | Whole TUI CPU s |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 2 | control | 71 | 0.323917 | 1.161458 | 3.719041 | 0.534493 |
| 2 | candidate | 76 | 0.302833 | 0.667958 | 1.337917 | 0.474230 |
| 30 | control | 67 | 0.921167 | 2.517000 | 6.843958 | 0.569618 |
| 30 | candidate | 62 | 0.846917 | 1.648500 | 3.518416 | 0.516914 |

The 300-control process exceeded the probe's read-only operation-observation
deadline after provider release. Its terminal receipt has **351** observed
successes. After cleanup, its separate SQLite backup/reread contains **600
succeeded rows**. That later inventory does not establish when the remaining
249 completed or why the API observation lagged. The failure means incomplete
observation within the deadline, not 249 demonstrated failed operations.
The deadline was not extended to make this arm pass.

The failed arm's server exits 0, is reaped without forced kill, and its provider
handlers and sampler stop. Source/resource checks admit the next arm. The
independent 300-candidate arm completes and validates **600/600**, with 85 list
Build samples, p50 **3.048792 ms**, p95 **7.832958 ms**, maximum **13.271250 ms**
and whole-TUI CPU **1.380340 s**. It is a single candidate observation. Both
300 arms have `pair_comparison_eligible=false`; no 300-owner improvement ratio
is inferred. Failed-arm timing remains in the raw report as diagnostics only.

The successful candidate still records three settlement-read timeouts recovered
by read-only retries, and 45 fallback waits for HTTP 429, totaling 45.16109092 s
over the whole workload. The failed control records five observation-read
failures and ten fallback waits. These are not TUI Build failures or counts
restricted to the released-model phase. Final operation success does not mean
that all observation requests completed without retries or waiting.

The [primary analysis](matrix/analysis-v2.json) distinguishes `arm_eligible`
from `pair_comparison_eligible`. The preserved v1 field `comparison_eligible`
meant only individual arm eligibility; it must not be read as pair eligibility.

## Admission and retained identities

The invoked controller uses explicit source, digest, owned-process, cleanup and
workload checks before expansion. Its command and per-arm execution/qualification
receipts are retained. Current raw reports are independently reparsed and
requalified by the retained analysis. Source/resource safety and successful
workload eligibility remain separate, allowing a safely cleaned failed large
arm to be followed by the next arm while the final matrix stays false.

The outer controller and qualifier were not independently byte-pinned in their
execution receipt. Their retained copies/hashes are read-after identities,
not proof of those exact bytes at invocation. The child probe/observer hashes
and native binary source/digests have their own recorded bindings. The common
fixture/source directories were not continuously monitored. No formal GitHub
approval, main integration, installed behavior, actual UI cardinality, key
application, physical display or 100 us completion is established here.

[provenance.json](provenance.json) pins **134** selected exact source/capture
pairs, 10,627,604 bytes, read after execution. Eighteen owned admin/dashboard/TUI
token values were privately checked against this selection with zero matches;
that is not a universal secret-absence claim. Auth configuration, full raw HTTP
and provider payload logs, native binaries and the full runtime are excluded.

To reanalyse, copy the bundle to a new ignored output directory and invoke
`matrix/analyze.py` with `--matrix matrix/measured-v1`, `--support support`
and a new `--output` path. It reads the original config embedded in the matrix
receipt. For a fresh workload, download source-matched native artifacts, verify
both binary readbacks, copy the frozen support/probe sources into a new ignored
directory and create a new config with new binary/fixture addresses and actual
digests. Retained command paths describe the original checkout; they do not
authorize writing into this bundle or certify edited future sources.
