# Keeper profile parse reuse: native measurements

Captured declarations bypassed the existing successful TOML parse cache, and a
declaration write cleared the parses for every other declaration. PR #46231
shares that existing cache with captured-content inspection and keeps per-file
entries across directory snapshot invalidation. Reuse requires the exact path
and complete captured string. Every capture still lists and rereads files;
read/parse/validation failures and downstream prompt dependencies remain checked.

In this four-cell 300-owner ABBA comparison, mean **health quick_stat-derived
allocation snapshot difference** was 66.917 GB for control and 59.843 GB for the
candidate, an observed **10.57% lower value**. This is a descriptive result from
two cohorts per role on a shared host. It establishes neither parser-exclusive
savings nor a stable latency improvement. Candidate status reads still timed
out, and the **0.1 ms goal is not achieved**.

## Source, build and validation

[Provenance](provenance.json) preserves exact source/diff, workflow and scope
identities. Code PR head is `5428e9a53dca4c41791dc412b952f8cd60466e0f` against
`9e08499e80c739b51923e816423873290932e27b`. The independently reviewed native
candidate is `55a0c7482fedece3f114fa8accb64a5084b1a796`; its only subsequent
code-PR delta is six portable browser fixture actor substitutions. Do not call
the binary a build of the later head.

| Record | Actual source and result |
|---|---|
| [Test 40357506337](https://github.com/jeong-sik/masc/actions/runs/40357506337) | 55a0c748, minimal/POSIX `test_keeper_toml`: failure, 111 cases/1 failure. All three captured-byte preservation cases passed; an existing browser actor fixture collided with the concrete-name inventory. |
| [Test 40359625516](https://github.com/jeong-sik/masc/actions/runs/40359625516) | 5428e9a5, same selected scope: success, 111 cases. The original failure remains a separate result. |
| [Minimal manual checks 40357511881](https://github.com/jeong-sik/masc/actions/runs/40357511881) | Builder 6a2d8dd6/application 55a0c748, resource-reading: success; all four selected native suites/logs exit 0. |

Both native application artifacts use workflow revision
`6a2d8dd6171e1d732ca15f918fb084e462e4d371`. Downloaded candidate archive digest,
server/TUI bytes, receipts and isolated embedded-commit commands matched.
See [candidate qualification](native/candidate-qualification.json),
[candidate receipt](native/candidate-receipt.json) and
[control receipt](native/control-receipt.json).

- Control application `c3cb3715e3a36b56ae17c23820b6b7c83914a602`, server SHA256
  `06ee93c99b31a6fca6786c2c6a676c8023b62b0fc854da6616518c21202ad3a8`.
- Candidate server SHA256
  `1d3da00a22f602005622af1f47442e1171f318e09dabc768123b946a4300f0cb`;
  TUI SHA256 `822b6436ea6e7f494b3e56598241a48a322b4dc523703608b9ac5ef1c7742559`.
- Common v3 runner `a6df19e949708fb6b44255e2a0623689c1ba9eb9e203c4a0eaf35f30ee537284`,
  reader `be6b0a62cf36d7174f43d2ff282285e8eb151fe8fe25583ee41c8c35c5976f9b`,
  runtime fixture `ccbe65e399f47a3abddbf4299e15dd0fd55001dd785b2e0d75948ad86acf7cfd`.

[Review bindings](reviews.json) record a current code-head source PASS with no
P0/P1/P2 findings. These are separate inherited-model session assessments,
not formal GitHub approvals. Full regression, primary installation, visible UI
and deployment were not performed. No local Dune build was run.

## Native workload and all four comparison cells

[Observations](observations.json) preserves every decoded value of the six-cell
derivative, with JSON whitespace compacted. The original byte digest is
`bed9b7328883ef8695d95c2716ed5c3d81e5792aed25688758344642822b0920`;
the separate retained digest is in [current locations](current-locations.json).
Candidate
qualification first completed 4 operations at 2 owners and 60 at 30 owners,
with held provider peaks 2/30. Both original runners and independent packet
reader checks passed. The [selected offline audit record](evidence-audits/summary.json)
checked original/backup stores, RPCs, held requests and cleanup. At 30 owners,
two HTTP 429 attempts waited 2.0068 s and successful settlement status maximum
was 1603.128 ms; those smaller runs do not establish a 0.1 ms result either.

Every 300-owner cell completed **600 original operations and 600 actual scripted
model calls**, with 300 held provider handlers at the release barrier. The same
runner, reader, source fixture and explicit parameters were used: two inputs per
owner, 10 ms reply delay after intentional hold, 1200 s settlement observation
deadline, 15 s request timeout and 0.1 s health sampling. No native sample or
profiling GET was added to these comparison runs.

| Cell, execution order | Snapshot difference, GB | Successful settlement status max, ms | Status timeouts | Health/live max, ms | HTTP 429 | Denied inventory calls |
|---|---:|---:|---:|---:|---:|---:|
| A1: control c3cb371 | 66.061404224 | 3824.874 | 3 | 4821.880 | 54 | 1202 |
| B1: candidate 55a0c748 | 59.518647344 | 6768.155 | 1 | 4233.564 | 61 | 602 |
| B2: candidate 55a0c748 | 60.168136584 | 9413.168 | 1 | 3248.204 | 62 | 602 |
| A2: control c3cb371 | 67.772296120 | 14115.201 | 0 | 3444.437 | 65 | 602 |

The mean compares the two complete cohort differences per role, without pooling
only successful RPC samples. Successful-status maxima exclude timeouts; all
five failed read observations remain recorded separately and recovered through
reads of the same owner/operation, without replaying mutations. Every original
runner and official reader verdict was PASS. Health/live samples were valid
1243/1243, 1021/1021, 1059/1059 and 1049/1049 respectively; health validity does
not mean all RPC observations succeeded.

Inventory work varies: A1 denied 1200 volume-inspection commands plus two
inventory commands; the other cells denied 600 plus two. No guest command
executed. The variation, rate waits, deliberate hold, shared-host work and
two-cohort sample limit prevent sole-cause or stable SLO conclusions. Creation
attempt envelopes were 13.127/13.361/13.535/13.520 seconds; a broad startup or
end-to-end latency improvement is not established by the allocation observation.

## Counter, authority and readiness boundaries

The allocation difference is
`((minor_words + major_words - promoted_words)_after - (...)_before) * 8`
for this 64-bit platform. The server computes these top-level GC fields through
`Gc.quick_stat` in each health probe, outside the nested full-health cache.
The counters can lag collection boundaries. This is a whole-program snapshot
derivative, not `Gc.allocated_bytes()`, parser-only allocation, RSS, CPU, an
allocation rate or exact phase-boundary allocation.

The before/after health JSON objects retain source/hash, runtime instance,
PID and private roots. V3 saves parsed full-health objects, not their original
HTTP response bytes/headers or request/return clocks; this bundle does not
claim to audit that missing wire provenance. Nested full-health sensors may be
cached. Resident, model-held and after full-health snapshots were `degraded` with
`keeper_memory_execution:addon_unattached` and operator action required.
Initial before snapshots were still warming.

The observation helper originally lacked runtime/PID/root/time joins. The
[review records](reviews.json) preserve the original CR, the response adding
those joins and the independent delta PASS for exact helper
`d67dab60f7f86e49b94355738999c54860796f150946a0db1963a03632b8b6c8`, including
the old counterexample and six independently written rejection probes. The old
finding remains attached to its old bytes. Only the repaired helper generated
this complete six-cell derivative after every runner/reader closed.

The [300-owner offline audit summary](evidence-audits/summary.json) records 2400
distinct original/backup databases through 3600 immutable read-only opens and
20 byte-identical regenerated reader derivatives. It also independently checked
the full six-row aggregate, all role means, negative attempts, actual fixture
and inventory variation. Full reports and input-hash manifests stay in the
recorded local audit packages; these selected summaries are new derivatives,
not byte copies of those full manifests.

## Retention and reproduction

The [frozen plan](reproduction/plan.json), [input qualification](reproduction/execution-qualification.json)
and [analysis source](reproduction/derive_observations.py) retain captured paths.
The analysis reads existing records and requires a new explicit output path;
run it without Python optimization, outside this retained bundle's output.
It launches no native/HTTP/SQL operations. The public v3 workload/reader source
is under `scripts/harness/perf/` in the code stack.

[Current locations](current-locations.json) maps selected records to the original
local package context. Frozen review links and path/hash manifests describe
their captured packages; not every referenced snapshot is included here.
Full private packets, original SQLite/WAL/logs, credentials and copied native
executables remain under `artifacts/runs/extreme-perf-20261026/`. Raw RPC bodies,
credentials and executables are absent from this selected versioned bundle.
Every owned server exited/reaped without forced kill; listeners/handlers drained
and original bases were retained.

These experiments demonstrate native queue/durability behavior with one admin
producer and a scripted loopback text model. External model throughput, peer
business calls, broadcast, actual Add-on/guest tools, visible TUI and general
file/Markdown/HTML communication latency remain unproven. They do not complete
the broader performance goal.
