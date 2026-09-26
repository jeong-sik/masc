# ASCII predicate inline follow-up: code generation and HTTP comparison

## Verified source and emitted code

Baseline `8c23cd524c28048a0f3a859fb86f4e001428c9a9`, artifact `10907429339`,
[build 36246971815](https://github.com/jeong-sik/masc/actions/runs/36246971815),
versus candidate `c60d967b19a96d01523d830a777df0c39703c7cc`, artifact `10908567580`,
[build 36249065961](https://github.com/jeong-sik/masc/actions/runs/36249065961).
ZIP digest/size/members, repository/run/source, and all three binary hashes were
verified for each artifact. Both manifests report `release_validated:false`.
Every owned server matched its expected source, binary SHA, isolated root and
zero Keeper fibers at startup.

Only `lib/core/safe_ops.ml` differs between these arms: adding `[@inline]` to the
unchanged control-character predicate. The complete sanitizer and its tests
match PR #39325 source head `7e9135c72ecbc28749c0b65bba6527e7e170aefc`; the PR and
probe have different bases, so this is not whole-repository equality. Neither
arm includes the backlog encoding reuse change. `source-scope.json` retains
exact file hashes.

The verified baseline binary's `first_repair` ASCII branch calls
`is_disallowed_control_char` with surrounding register save/reload instructions.
The candidate's corresponding branch contains the comparisons directly and no
predicate call. The non-ASCII decoder call remains. Exact commands, symbols,
binary hashes and disassembly hashes are retained beside the two assembly
files. **This proves the emitted call removal, not a latency improvement or the
cause of the earlier regression.** Only this function's code was inspected.

## Method and retained checks

24 sequential sessions on a shared macOS host: ASCII or Korean/ASCII task
descriptions × identity/gzip GET requests × three repetitions × two arms.
Order is baseline/candidate, candidate/baseline, baseline/candidate. Each session
seeds 250 tasks then performs 20 add-task → first execution GET → warm GET cycles.
Arm path suffixes `before`/`after_` have equal lengths. This uses the unchanged
normal-level measurement runner; the separate debug-log diagnostic is excluded.

All 480 mutation acknowledgements and 960 GETs completed. Expected binary/source/
run/artifact identities, argument hashes/order, response task fields except
created/updated timestamps, publication generations, actual encoding and cleanup
were checked. All owned servers exited zero and were reaped. Only local model-
list GETs reached the owned stub; no operator credentials, production settings,
production deployment or restart were involved.

Each first GET has `cache_compute` and the new Task; each warm GET lacks it and
returns the same parsed body. This is a prepared-route miss, not a claim that
all internal caches are cold. Response projections truncate long descriptions.
Separate checks of all persisted backlogs verified 270 tasks/revision 34, every
full generated description, all stored task fields except the two timestamps
within each text kind, and exact primary/recovery byte equality. All 48 files
are retained separately. ASCII and multilingual seed descriptions have equal
UTF-8 byte lengths; not every server string in the ASCII group is ASCII.

Timings cover a fresh TCP request through complete body read, excluding request
JSON construction and response parsing/decompression. The mutation metric is
the entire acknowledgement, not sanitizer CPU time. GET encoding labels describe
the following GET; all MCP responses were identity encoded. Conditions and
phases are not pooled. Each table cell contains 60 observations per arm.

## Results

Milliseconds: median / nearest-rank p95 / maximum. Full minimum, bytes,
server-compute and per-session data are in `summary.json`. No tail was dropped.

### Task acknowledgement

| Descriptions / GET encoding | Baseline | Candidate |
|---|---:|---:|
| ascii / identity | 18.815041 / 29.671875 / 38.555500 | 17.498312 / 22.041625 / 31.528083 |
| ascii / gzip | 17.703208 / 20.239916 / 25.215416 | 16.830000 / 19.089084 / 19.769792 |
| multilingual / identity | 18.580792 / 22.576125 / 42.379208 | 17.512937 / 18.993584 / 21.166334 |
| multilingual / gzip | 18.594188 / 20.067084 / 22.267459 | 18.514083 / 41.262375 / 109.436000 |

### First execution GET

| Descriptions / GET encoding | Baseline | Candidate |
|---|---:|---:|
| ascii / identity | 11.596542 / 12.294250 / 13.028792 | 11.800500 / 12.478541 / 17.117833 |
| ascii / gzip | 11.693125 / 12.199958 / 12.659083 | 11.492792 / 12.007375 / 12.264375 |
| multilingual / identity | 12.184646 / 12.805750 / 13.792125 | 11.989313 / 12.652291 / 15.233916 |
| multilingual / gzip | 12.141334 / 12.512791 / 12.809250 | 12.170708 / 12.744459 / 13.439167 |

### Warm execution GET

| Descriptions / GET encoding | Baseline | Candidate |
|---|---:|---:|
| ascii / identity | 0.484791 / 0.610250 / 1.399375 | 0.513437 / 0.609375 / 1.687375 |
| ascii / gzip | 0.471813 / 0.601875 / 0.672000 | 0.471916 / 0.566416 / 0.653042 |
| multilingual / identity | 0.516042 / 0.635333 / 0.692417 | 0.512312 / 0.617125 / 0.672292 |
| multilingual / gzip | 0.479938 / 0.578125 / 1.058584 | 0.483459 / 0.600625 / 1.080458 |

Mutation medians are lower in all four aggregate groups. Both ASCII conditions
and multilingual/identity improve in all three repetitions; multilingual/gzip
improves in two of three. **Multilingual/gzip mutation p95 and maximum worsen**,
including the retained 109.436ms maximum. No uniform response bound follows.

GET results remain mixed: ASCII/identity first-GET medians worsen in all three
repetitions; multilingual/identity first-GET medians improve in all three.
Multilingual/gzip warm medians worsen in all three. The ASCII/gzip warm aggregate
median difference is only about 0.000104ms and does not establish meaningful
change. Other GET regressions in p95/max are retained in the tables.

The host was not CPU isolated. The source and disassembly establish less work
in the ASCII branch, but these round trips do not isolate that CPU saving,
identify tail causes, or establish a statistically proven general speedup. No
allocation measurement was made. Every candidate observation exceeds 0.1ms.
Deployment, browser, physical-display and Keeper continuity performance are
not proved by this experiment.

## Compiled checks

Source head `7e9135c72ecbc28749c0b65bba6527e7e170aefc` passed all five
[PR gates 36248730406](https://github.com/jeong-sik/masc/actions/runs/36248730406).
[Probe focused 36249067818](https://github.com/jeong-sik/masc/actions/runs/36249067818)
completed successfully: 72 safe_ops and 59 json_util cases (131 total).
[PR focused 36248959082](https://github.com/jeong-sik/masc/actions/runs/36248959082)
has a successful compiled Test step; the full workflow was still in progress
when recorded. Earlier non-inline candidate tests are distinct from these runs.
No local OCaml build was performed. A later evidence-only PR head needs its own
gates.

Root restored all 197 receipts and reproduced the exact summary. Independent
adversarial review checked all observations, source/binary identities, full
stored backlogs and repetition directions, and regenerated identical native
disassembly. Independent response review reconciled both archives and assembly
hashes, statistics and limitations. No additional performance run was made by
either reviewer.

## Reproduction

`receipts.tar.xz` retains 197 exact receipt files: scripts, plan, summary,
stdout/stderr/exit status, identity, mutation acknowledgements, observations,
cleanup and parsed responses. Response gzip files are stored as their exact
decompressed JSON bytes; original-file and member hashes are retained in
`receipt-files.json`. `persisted-backlogs.tar.xz` contains all 48 full synthetic
primary/recovery files, hashed in `persisted-backlogs.json`. Original HTTP bytes
were not retained, so runtime byte-hash equality and reproducible parsed-body
equality remain distinct. No real runtime data, auth tokens or raw server logs
are published.

```sh
python3 restore.py . /tmp/masc-inline-receipts
python3 /tmp/masc-inline-receipts/summarize.py /tmp/masc-inline-receipts
```

The exact executed commands are in `plan.json`. To repeat with verified artifacts
and a checkout containing the retained `runtime-fixture.toml`:

```sh
python3 compare.py --repo "$MASC_CHECKOUT" --runner "$PWD/session.py" \
  --output "$NEW_MEASUREMENT_DIR" \
  --baseline "$BASELINE_ARTIFACT" \
  --baseline-commit 8c23cd524c28048a0f3a859fb86f4e001428c9a9 \
  --baseline-run 36246971815 --baseline-artifact 10907429339 \
  --candidate "$CANDIDATE_ARTIFACT" \
  --candidate-commit c60d967b19a96d01523d830a777df0c39703c7cc \
  --candidate-run 36249065961 --candidate-artifact 10908567580
python3 summarize.py "$NEW_MEASUREMENT_DIR"
```
