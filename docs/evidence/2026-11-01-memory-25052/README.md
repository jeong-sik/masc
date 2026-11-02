# Current Memory OS metadata observation

Read-only operating evidence for [#25052](https://github.com/jeong-sik/masc/issues/25052).
The issue remains open for relevant retrieval and actual use, matched workload
growth measurements, and live shared provider admission. No runtime state,
configuration, memory, journal or provider request was changed or generated.

## Identity and observation windows

The health endpoint identified runtime instance
01a19489-2a83-7000-9869-7048022414f7, installed commit
dbd032511fea4e3d04687448275c0f41abff56cc and effective root
/Users/dancer/me/.masc. These identities were unchanged before and after the scan.
The listener's inspected environment did not set MASC_CONFIG_DIR; the admitted
base path and Config_dir_resolver place configuration under .masc/config.
Ordinary snapshot files are in **config/keepers**, while dated TurnRecords are in
**keepers/<name>/turn-records**. An empty snapshot search in the latter directory
would not establish memory absence.

The TurnRecord timestamp window is process start **2026-11-01T00:36:19Z through
01:47:38.047978Z**. Sequential file observations ran **01:47:38.048146Z through
01:47:38.219658Z**. Snapshot observations include dormant Keepers and are not
atomic across the fleet. All 44 paths were stable during their individual read.

| Observation | Result |
| --- | --- |
| Ordinary current snapshots | 44; 3,608,726 bytes; 2,337 fact entries |
| Snapshot file sizes | 190–210,698 bytes; median 70,171 |
| JSON TurnRecord rows in the runtime window | 139; 139 distinct turn_ref values |
| Observed memory_os_recall assembly blocks | 119; 1,051–1,149 bytes; median 1,055 |
| Attributed prompt.memory_os_recall components | 24; 1,051–1,149 bytes; median 1,054 |
| Whole serialized request-body observations | 27; 260,757–2,011,788 bytes; median 1,167,483 |
| Historical memory journal file sizes | 147,476,063 bytes in total; metadata only, no journal bodies read |
| Snapshot JSON or TurnRecord JSON read/decode errors | 0 |

Assembly block bytes, attributed memory payload, complete serialized request
bytes, snapshot disk bytes and historical journal sizes are separate measures.
The small recall block does not explain the rest of a request's bytes. Missing
blocks/components are unknown, not zero; the latest serialized request can be a
post-tool round that intentionally omits first-round recall. A recorded request
body does not prove HTTP delivery, provider success or use of recalled facts.
The Python collector inspected JSON metadata; it did not execute the OCaml
Turn_record decoder or certify that every recorded row represents a successful
turn.

The six inspected recall, snapshot, assembly, configuration-resolution and
TurnRecord source files have byte-identical hashes at the installed commit and
this checkout. That validates the inspected schema comparison, not which branch
each request actually took. Health reports the Librarian outputs as configured
and serving, with provider_execution=not_proven_by_availability. It does not
establish a successful Memory commit or cross-Keeper admission effect.

This is one current snapshot observation. It does not establish a growth rate,
provide a controlled comparison with October's different workloads, score
semantic relevance, or authorize retention/deletion limits. The old 583 MB /
154 MB-per-day findings are not reused as current facts.

## Reproduce and provenance

[observation.json](observation.json) contains metadata, counts, turn identities,
byte lengths and digests. It contains no memory claim bodies, prompt bodies or
credentials. [manifest.json](manifest.json) records the exact source and copied
capture hashes. The initial capture's component filter was corrected from block
identifiers to Turn_record's canonical prompt.<block> identifiers; its original
bytes remain separate in ignored artifacts and are not silently rewritten.
The retained helper additionally rejects existing outputs before collection,
requires a resolved path under the selected repository's artifacts directory,
and creates the final file exclusively. Its digest is recorded separately from
the original capture-time helper; the collection logic is unchanged.
[Collector output checks](collector-output-checks.json) record a fresh output,
refusal of a repeat before health access, preservation of existing bytes, and
refusal of a resolved parent-symlink escape. That output probe is separate from
the retained Memory OS observation above.

Run the retained [collector](observe-memory-25052.py) against the affected
runtime's health URL and admitted configuration root, selecting a **new output
path under artifacts/** for every run:

```sh
python3 docs/evidence/2026-11-01-memory-25052/observe-memory-25052.py \
  --health-url 'http://127.0.0.1:8935/health?full=1' \
  --config-root /Users/dancer/me/.masc/config \
  --repo /Users/dancer/me/workspace/yousleepwhen/masc \
  --out artifacts/memory-observation-next/observation.json
```

Paths in this command identify the observed host; they are not product defaults.
Refresh effective runtime roots and the listener's configuration override before
reusing it elsewhere.
