# Sanitizer comparison: task acknowledgement and execution responses

## Method and verified identity

- Baseline `887807abe0bfb2b3d2df7fbca7672faa199aa898`, artifact `10905529982`,
  [build 36241015541](https://github.com/jeong-sik/masc/actions/runs/36241015541).
- Candidate `8c23cd524c28048a0f3a859fb86f4e001428c9a9`, artifact `10907429339`,
  [build 36246971815](https://github.com/jeong-sik/masc/actions/runs/36246971815).
- The only product diff is `lib/core/safe_ops.ml`. Candidate sanitizer/test
  files match PR source head `3bb71cc0ff954d5a7c81b7d4ff5cd474439767c2`.
  `source-scope.json` records hashes and the compared paths. The benchmark
  candidate predates later evidence-only PR commits and is not a build from
  the integrated main-based PR head.
- Both ZIP digests, artifact/source/run/repository identities and all three
  binary hashes were verified. Every running server's health identity matched
  its expected binary hash, source, isolated root and zero Keeper fibers.
  Both manifests report `release_validated:false`.
- The plan records expected identities before execution. Driver and aggregator
  reject identical sources or binaries across arms; each observed identity must
  match its expected source, server hash, artifact ID and run ID.
- One macOS host, sequential synthetic workspaces, owned loopback model stub,
  credential-free child environment except the fixture's synthetic credential.
  No production restart, deployment or configuration change.

Two input groups use ASCII or Korean/ASCII mixed **task descriptions**. This
is not a claim that every server string is ASCII in the first group. For each
input group and requested GET encoding (`identity`, `gzip`), three sessions per
arm alternate before/after, after/before, before/after. Each seeds 250 tasks,
then performs 20 add-task → first GET → warm GET cycles. Equal-length
`before`/`after_` paths avoid the earlier experiment's path-length difference.

All **24 sessions, 480 mutation acknowledgements and 960 GETs** completed.
Each metric cell has 60 samples per arm. All planned observations are retained;
no tail is dropped. Task argument hashes/order match within each input group.
Every returned task projection field except `created_at`/`updated_at` matches
across arms and encodings. The projection truncates long descriptions, so this
comparison of response fields is not itself a full stored-description check.
A separate read of all 24 stopped workspaces verified 270 stored tasks at
revision 34, every full seed description against its generated input, and all
stored task fields except those two timestamps within each input group. Primary
and last-good bytes matched in every session. The 48 exact files are retained
separately in `persisted-backlogs.tar.xz` with hashes in `persisted-backlogs.json`.
The two description fixtures have equal UTF-8 byte lengths (for seed 0, 1178
bytes each) while their character counts differ.

Every first GET has `cache_compute`, increased generation and the added Task;
warm GETs lack `cache_compute` and have the same parsed body. This establishes
a post-mutation prepared-route miss, not that every internal cache is cold.
Original decoded-HTTP hashes were asserted equal first/warm at runtime, but
original HTTP bytes are not retained for independently rebuilding those hashes.
The full parsed-body comparison is independently reproducible.

MCP timing starts before a new TCP request and stops after its complete HTTP
response body arrives. It covers the entire task acknowledgement, including
server admission, persistence, broadcasts and HTTP handling. It excludes
request JSON construction and response JSON parsing. **It is not sanitizer
execution time.** GET timing has the same boundary and excludes decompression.
The encoding label below describes the session's GET request, not its MCP
request; all observed MCP responses were identity encoded.

## Results

Milliseconds; median / nearest-rank p95 / maximum. Counts are 60 per arm per
row. `summary.json` also retains minimum, bytes, server timing and per-session
values. Input groups, encodings and phases are not pooled.

### Task acknowledgement

| Task description / following GET encoding | Baseline | Candidate |
|---|---:|---:|
| ASCII / identity | 18.077000 / 22.686291 / 28.105833 | 18.742959 / 20.904667 / 23.218458 |
| ASCII / gzip | 20.405271 / 63.012333 / 140.403417 | 17.884771 / 28.898750 / 79.056542 |
| Multilingual / identity | 31.594146 / 172.680291 / 258.366917 | 27.662876 / 57.036042 / 133.813625 |
| Multilingual / gzip | 19.568104 / 23.346541 / 24.859167 | 17.756417 / 20.442625 / 25.596209 |

Multilingual mutation medians were lower in all three repetitions for both
GET encodings. **ASCII/identity mutation median increased**, and two of its
three repetitions worsened. Multilingual/gzip's maximum increased. No general
latency improvement or uniform bound follows from these observations.

### First execution GET

| Task description / requested encoding | Baseline | Candidate |
|---|---:|---:|
| ASCII / identity | 11.838708 / 13.342958 / 18.638625 | 11.629645 / 13.058541 / 13.774834 |
| ASCII / gzip | 12.784042 / 28.109833 / 93.481625 | 11.653876 / 12.999583 / 16.652667 |
| Multilingual / identity | 14.410896 / 32.255875 / 68.762625 | 15.143813 / 26.170583 / 36.241958 |
| Multilingual / gzip | 12.257125 / 14.211334 / 16.365917 | 11.943375 / 12.809583 / 13.298500 |

**Multilingual/identity's first-response median increased.** The other first
medians fell, but not every repetition improved. Both binaries already include
#39303 and actually honor the requested GET encoding on first and warm reads;
there is no first-response identity→gzip change between these two arms.

### Warm execution GET

| Task description / requested encoding | Baseline | Candidate |
|---|---:|---:|
| ASCII / identity | 0.492208 / 0.597459 / 1.013542 | 0.485771 / 0.604625 / 2.426792 |
| ASCII / gzip | 0.568542 / 4.337833 / 7.594500 | 0.453979 / 0.593042 / 0.976083 |
| Multilingual / identity | 0.614167 / 10.162000 / 60.799708 | 0.689605 / 2.540667 / 5.379875 |
| Multilingual / gzip | 0.476479 / 0.617917 / 0.789416 | 0.433875 / 0.608875 / 0.735625 |

ASCII/identity warm p95 and maximum increased. Multilingual/identity warm median
increased. Large tails appear even in warm reads. The shared host was not CPU
isolated; the evidence cannot identify their cause or attribute all variation
to this source change. Three sessions and related within-session samples do
not establish a statistically proven speedup. No CPU or allocation volume was
measured. The 0.1ms goal remains unmet, including every candidate observation.

## Checks and reproduction

PR head `3bb71cc0ff954d5a7c81b7d4ff5cd474439767c2` passed all five
[PR gates 36246956750](https://github.com/jeong-sik/masc/actions/runs/36246956750).
[Focused CI 36246925431](https://github.com/jeong-sik/masc/actions/runs/36246925431)
and [candidate focused CI 36246973911](https://github.com/jeong-sik/masc/actions/runs/36246973911)
each passed 72 safe_ops + 59 json_util cases (131), including all 256 byte
assertions in the new boundary scenario. No local OCaml build was performed.
New evidence-only heads require their own PR gates.

`receipts.tar.xz` losslessly retains 197 files: exact as-run scripts, plan,
summary, stdout/stderr/exit receipts, identities, tool results with mutation
HTTP timings, cleanup and parsed GET responses. The original response gzip
files are stored as their exact decompressed JSON receipt bytes to compact
repetition. `receipt-files.json` includes original-file and archived-member
hashes. No real runtime data, auth token, server runtime directory or server
log is published. All server children exited 0 and were reaped; the only model
requests were local model-list GETs. A separate observer smoke ran two cycles;
it is not included in the comparison.

Root restored all 197 members and regenerated exactly the same aggregate and
per-session summary. Independent adversarial review reconciled all observations,
inputs, identities, stored backlogs and aggregate values. Independent response
review confirmed the statistics and the mixed interpretation. Neither reviewer
executed another performance run.

From this directory, restore to a new directory and recompute:

```sh
python3 restore.py . /tmp/masc-sanitizer-receipts
python3 /tmp/masc-sanitizer-receipts/summarize.py /tmp/masc-sanitizer-receipts
```

The full executed commands are in `plan.json`. To repeat with the retained
script and verified/unpacked artifacts (no local build):

```sh
python3 compare.py --repo "$MASC_CHECKOUT" --runner "$PWD/session.py" \
  --output "$NEW_MEASUREMENT_DIR" \
  --baseline "$BASELINE_ARTIFACT" \
  --baseline-commit 887807abe0bfb2b3d2df7fbca7672faa199aa898 \
  --baseline-run 36241015541 --baseline-artifact 10905529982 \
  --candidate "$CANDIDATE_ARTIFACT" \
  --candidate-commit 8c23cd524c28048a0f3a859fb86f4e001428c9a9 \
  --candidate-run 36246971815 --candidate-artifact 10907429339
python3 summarize.py "$NEW_MEASUREMENT_DIR"
```

The checkout runtime fixture must match the retained `runtime-fixture.toml`.
These results do not establish deployed, browser or physical-display performance.
