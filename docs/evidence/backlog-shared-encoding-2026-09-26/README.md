# Backlog encoding reuse: controlled HTTP comparison

## Identity and source scope

Baseline `8c23cd524c28048a0f3a859fb86f4e001428c9a9`, artifact `10907429339`,
[build 36246971815](https://github.com/jeong-sik/masc/actions/runs/36246971815),
versus candidate `c1997e8d770fe7c6c60677563956409b97cb0eb5`, artifact `10908661001`,
[build 36248257971](https://github.com/jeong-sik/masc/actions/runs/36248257971).
Both artifact ZIP sizes/digests, repository/run/source identities and all three
binary hashes were verified. Every owned server matched the expected source,
binary SHA, isolated workspace and zero Keeper fibers at startup. Both manifests
report `release_validated:false`.

The only product differences between these arms are `workspace_backlog.ml`,
`workspace_utils_ops.ml` and `workspace_utils_ops.mli`. Those three complete files
match PR #39330 at `f4feb04d600cf4544c2c4b64131a08dce1f7e407`. The PR and
comparison branches have different bases; this is not whole-repository equality.
The sanitizer is unchanged between arms. In particular, the later ASCII inline
follow-up in #39325 is absent. See `source-scope.json` for exact file hashes.

## Method

24 sequential isolated sessions on one shared macOS host: ASCII or Korean/ASCII
task descriptions × identity/gzip GET requests × three repetitions × two arms.
Order is baseline/candidate, candidate/baseline, baseline/candidate. Each session
seeds 250 tasks, then performs 20 add-task → first execution GET → warm GET cycles.
The arm path suffixes `before` and `after_` have equal lengths. No production
restart, deployment or configuration change was made. Child environments use an
explicit allowlist without operator credentials; the model stub only received
local model-list GETs.

All 480 mutation acknowledgements and 960 GETs completed. Argument hashes/order,
expected source/binary/run/artifact identities, publication generations, actual
HTTP encoding, task fields except created/updated timestamps, and cleanup were
checked across all sessions. All owned servers exited zero and were reaped.
The plan and aggregator reject equal source identities or binary hashes across
arms. Each first GET includes `cache_compute`; each warm GET lacks it and returns
the same parsed body. This identifies a prepared-route miss following mutation,
not that every internal cache is cold.

Task descriptions are long: the response projection truncates them. Separate
checks read all 24 persisted backlogs, verified each full generated description,
270 tasks at revision 34, all task fields except created/updated timestamps
within each text kind, and exact primary/recovery byte equality. Those 48 files
are retained in `persisted-backlogs.tar.xz`. The two input kinds have equal UTF-8
byte lengths for each seed description; not every server string in the ASCII
input group is ASCII.

Each timing covers a fresh TCP request through the full HTTP body read. Request
JSON construction and response parsing/decompression are excluded. Mutation
measurements include the whole acknowledgement path, not isolated serialization
CPU time. Encoding labels refer to the following GET; all MCP acknowledgements
were identity encoded. Input kinds, GET encodings and phases are not pooled.

## Results

Milliseconds: median / nearest-rank p95 / maximum, 60 observations per arm in
each row. Full minimum/byte/server-compute and per-session values are retained
in `summary.json`. No observations or tails were removed.

### Task acknowledgement

| Descriptions / GET encoding | Baseline | Candidate |
|---|---:|---:|
| ascii / identity | 19.500000 / 24.767250 / 27.594208 | 16.128396 / 59.480375 / 88.709833 |
| ascii / gzip | 19.478167 / 26.130583 / 109.197834 | 17.836562 / 22.124083 / 30.793750 |
| multilingual / identity | 18.728083 / 20.443833 / 21.835209 | 14.454562 / 44.960167 / 84.404333 |
| multilingual / gzip | 21.012938 / 78.914667 / 98.405458 | 19.286875 / 45.787375 / 53.485292 |

### First execution GET

| Descriptions / GET encoding | Baseline | Candidate |
|---|---:|---:|
| ascii / identity | 11.773708 / 14.214375 / 15.000416 | 13.092479 / 18.553041 / 21.884917 |
| ascii / gzip | 12.089313 / 15.577500 / 16.561334 | 13.103354 / 15.314417 / 15.537708 |
| multilingual / identity | 12.313354 / 13.276667 / 14.657750 | 12.821771 / 22.929833 / 29.305000 |
| multilingual / gzip | 12.757791 / 19.371125 / 25.836333 | 13.794145 / 25.422208 / 29.316208 |

### Warm execution GET

| Descriptions / GET encoding | Baseline | Candidate |
|---|---:|---:|
| ascii / identity | 0.480688 / 0.665250 / 0.711167 | 0.562021 / 0.984709 / 1.284708 |
| ascii / gzip | 0.494604 / 0.683167 / 1.200959 | 0.543875 / 0.656875 / 0.797042 |
| multilingual / identity | 0.519417 / 0.768875 / 2.419333 | 0.570979 / 2.605458 / 3.647791 |
| multilingual / gzip | 0.499375 / 2.152000 / 12.370542 | 0.589562 / 3.333375 / 6.064000 |

Mutation medians are lower in all four aggregate groups, but only two of three
repetitions improve in each group. Both identity groups have worse mutation p95
and maxima. **Every aggregate first and warm GET median is higher.** Multilingual
identity first-GET medians worsen in all three repetitions; ASCII/gzip warm
medians also worsen in all three. Most GET p95/max values worsen, with exceptions
visible in the tables. These results do not establish an overall speedup.

The shared host was not CPU isolated. The source removes duplicate encoding,
but the observations cannot identify the cause of the tails or attribute all
GET regressions to that change. No isolated CPU or allocation measurement was
made. Three sessions per condition, with related observations within sessions,
do not establish statistical confidence or a uniform response bound. Every
candidate observation remains above 0.1ms. Deployment, browser, physical display
and Keeper continuity are outside this measurement.

## Compiled regression status

The original PR [gates 36247999336](https://github.com/jeong-sik/masc/actions/runs/36247999336)
and focused runs [36247999129](https://github.com/jeong-sik/masc/actions/runs/36247999129)
and [36248259741](https://github.com/jeong-sik/masc/actions/runs/36248259741) failed
the new repair test. Its assertions for sanitization, revision and initial
primary/recovery bytes passed; its lock call passed a filesystem path as a
backend key. The backend rejects slashes, and lock retry then reached an unset
test clock before repair assertions executed. This is a real test defect, not
a completed regression pass. The first focused run separately passed 13 deletion
and 68 writer cases; the workspace suite had one failure among 89 cases.

PR `f4feb04d600cf4544c2c4b64131a08dce1f7e407` changes the test to the production
path-aware `with_file_lock` helper without weakening assertions. Probe
`f9ea43e96349c1da634b7b8586412d187f984851` carries the same test-only correction.
The measured candidate predates this correction, with unchanged product source.
New compiled results are pending in PR gates 36249117845, PR focused 36249138674,
and corrected probe focused 36249181453. Both source reviewers confirmed the fix;
no local OCaml build was performed. New evidence heads need their own PR gates.

## Retained evidence and reproduction

`receipts.tar.xz` losslessly retains 197 files: exact scripts, plan, summary,
per-session stdout/stderr/exit receipts, identity, mutation tool acknowledgements,
observations, cleanup and parsed GET responses. Gzipped response receipts are
stored as exact decompressed JSON bytes. `receipt-files.json` records original
and archived-member hashes. `persisted-backlogs.json` hashes the 48 complete
synthetic primary/recovery files. Original HTTP bytes were not retained: runtime
hash assertions and independently reproducible parsed-body equality are distinct.
No real runtime data, auth tokens or raw server logs are published. Root restored
all 197 files and reproduced the exact summary. Independent adversarial review
recomputed all observations and verified complete stored backlogs and the mixed
interpretation. Independent response review also checked both archives against
originals, all hashes, tables, repetition directions and failed-CI accounting;
it found no blocking defect or overstatement.

Restore to a new directory and recompute:

```sh
python3 restore.py . /tmp/masc-backlog-receipts
python3 /tmp/masc-backlog-receipts/summarize.py /tmp/masc-backlog-receipts
```

The exact executed commands are retained in `plan.json`. Repeat using verified
artifacts and the retained runtime fixture:

```sh
python3 compare.py --repo "$MASC_CHECKOUT" --runner "$PWD/session.py" \
  --output "$NEW_MEASUREMENT_DIR" \
  --baseline "$BASELINE_ARTIFACT" \
  --baseline-commit 8c23cd524c28048a0f3a859fb86f4e001428c9a9 \
  --baseline-run 36246971815 --baseline-artifact 10907429339 \
  --candidate "$CANDIDATE_ARTIFACT" \
  --candidate-commit c1997e8d770fe7c6c60677563956409b97cb0eb5 \
  --candidate-run 36248257971 --candidate-artifact 10908661001
python3 summarize.py "$NEW_MEASUREMENT_DIR"
```
