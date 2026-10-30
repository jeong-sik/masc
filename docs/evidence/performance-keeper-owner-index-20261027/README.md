# Keeper owner-handle index: interpreted module evidence

Routine projection reads searched the existing owner-handle association list for each key. Registry enumeration calls this lookup for each relevant entry. Replace that list with the existing `Set_util.StringMap` implementation. Preserve canonical key construction before the writer mutex, serialized install/remove, one immutable Atomic index snapshot per lookup, the selected Owner's current projection read, and physical-handle removal protection. Registry traversal ordering and metadata authority remain in their existing modules.

The helper's candidate production source is bound at historical commit `4d2fdfecdf9681d506c4ff0e9d76e9d89aadbee5` and by complete file hashes in [provenance.json](provenance.json). Those inventory bytes remain unchanged through the test repairs below. The provenance and its f5f1 test snapshot retain their original capture scope. Baseline is `f861e7c628ff5cfd504c7e85120c39a804a99c41`. Both complete inventory ML modules are interpreted in the generated program; neither algorithm was rewritten for measurement. **Owner projection is an Atomic int-option fixture, and canonicalization is identity on already canonical fixture paths.** This excludes real Owner actors, full projection structures and actual path/environment/filesystem validation from the helper measurement.

## Semantics and real-actor test boundary

The helper run completed 40,014 initial checks: seven exact stale-handle/live-projection/root-isolation/None-versus-absent assertions per role and 20,000 seeded reference-array steps checked against both roles. Another 5,312 state assertions around measured phases produce 45,326 total checks. Structurally equal but physically distinct handles verify that old cleanup preserves the replacement. Shared mutable projection cells remain live; projected integers are not cached in the index.

Separately, actual Owner tests in `test/test_keeper_owner.ml` cover canonical alias keys, identical initial metadata with distinct handles, replacement and stale removal, root isolation, live usage updates and metadata deletion while the handle remains installed. The concurrency case schedules two domains over 300 coordinated rounds with actual key additions, exact removals and alternating real handles. Both keys and generation markers are checked after each completed round before the next begins; stop flags and nested joins cover failed assertions/spawn/worker exits.

The original same-handle concurrency fixture was a logical Map.add no-op and was corrected after independent review. The initial finding and response remain in the local review records located by provenance. [test-response-checks.json](test-response-checks.json) retains parsing-only and source-boundary checks for the corrected test. The old parsing receipt for test hash 810572 and the corrected f5f1b816 response are historical. Neither the helper result nor those parsing-only checks establish real-actor execution, actual domain overlap or unlocked-mutant rejection. Later focused project CI is recorded separately below.

The selected Owner suite [40381210182](https://github.com/jeong-sik/masc/actions/runs/40381210182) failed before any cases ran: an inherited scheduled-source callback used an unannotated claimed-operation record. Its body and public interfaces matched baseline f861. A local `operation : Chat_operation.t` annotation resolved the same operation_id/execution_digest accesses without changing calls or behavior. [ci-response-checks.json](ci-response-checks.json) preserves parsing-only verification for test hash e0e23d49, subsequently committed at e6cd5474. The earlier captured provenance/test-response receipt stays bound to the 4d2/f5f1 concurrency-fixture snapshot; it does not certify later source. Both new projection tests and the complete production ML/MLI were unchanged by the annotation.

The later Owner suite [40387064153](https://github.com/jeong-sik/masc/actions/runs/40387064153) at `e6cd5474de4add4593d50d590bcdafa1a21c900c` compiled and ran 108 cases, with three failures in inherited scheduled-source-handoff cases 1, 2 and 7. Both new projection cases passed: replacement/root isolation (82) and concurrent writers (83). The complete suite failed. Its raw log is bound by [current-source-capture.json](current-source-capture.json); individual passing cases do not establish native performance or actual domain overlap.

The failed fixture returned success on a resumed operation while its durable semantic execution remained Suspended. Queue claim does not consume the retained checkpoint. The resumed fake executor now reads `Owner.direct_checkpoint` and calls `Owner.resume_direct_checkpoint` before its original success result, following the production continuation's Owner API sequence. Original assertions, ordering and timeout budgets remain intact; product transitions, Map ML/MLI and both new projection tests are unchanged. [ci-runtime-response-checks.json](ci-runtime-response-checks.json) is the exact parsing-only/whitespace receipt for the repaired test source `e9b3b09aa540e40266c27a95f8ad30be22e3c19657b0051b27558ce342a0e371`. This source capture was an uncommitted fixture repair after e6, distinct from the failed run's e0e23d49 test bytes. No fresh project-test or runtime success is supplied for the repair.

## All 72 measured phases

Each 2/30/300-entry population uses fixed baseline/candidate/candidate/baseline order, two cells per role. Each cell measures install, hit sweep, miss lookup, replace, stale remove and current remove. Lookup phases make 1,000 sweeps; mutation phases visit each key once. Source-controlled objects/names are prepared outside the counters. A full major collection precedes each phase outside its clocks/counters. Semantic work runs before measurement; no dedicated warmup or discarded outliers are used.

These are whole-phase medians. Entry counts are not live Keeper counts. Bookkeeping, key construction and fixture/adapter costs remain in the counter; actual canonicalization and real Owner execution do not.

| Entries | Phase | Calls/cell | Baseline ms | Candidate ms | Baseline allocated B | Candidate allocated B |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 2 | install | 2 | 0.0042715 | 0.0025415 | 664 | 640 |
| 2 | lookup_sweep | 2,000 | 0.4737915 | 0.4590000 | 256,208 | 256,208 |
| 2 | lookup_miss | 2,000 | 0.3755000 | 0.3497500 | 160,208 | 160,208 |
| 2 | replace | 2 | 0.0046460 | 0.0039170 | 688 | 640 |
| 2 | stale_remove | 2 | 0.0042710 | 0.0024795 | 656 | 528 |
| 2 | current_remove | 2 | 0.0020000 | 0.0017500 | 584 | 528 |
| 30 | install | 30 | 0.0225005 | 0.0242920 | 16,680 | 13,488 |
| 30 | lookup_sweep | 30,000 | 15.1383330 | 9.4549165 | 3,168,208 | 3,168,208 |
| 30 | lookup_miss | 30,000 | 20.3942090 | 8.8086660 | 2,400,208 | 2,400,208 |
| 30 | replace | 30 | 0.0394995 | 0.0199375 | 27,120 | 10,560 |
| 30 | stale_remove | 30 | 0.0518130 | 0.0177290 | 26,640 | 4,560 |
| 30 | current_remove | 30 | 0.0258335 | 0.0228955 | 15,480 | 8,280 |
| 300 | install | 300 | 1.5364370 | 0.2865835 | 1,136,640 | 195,024 |
| 300 | lookup_sweep | 300,000 | 882.4282295 | 117.7901045 | 31,248,208 | 31,248,208 |
| 300 | lookup_miss | 300,000 | 1671.3175835 | 107.3883125 | 24,000,208 | 24,000,208 |
| 300 | replace | 300 | 2.9639790 | 0.2343125 | 2,213,040 | 148,464 |
| 300 | stale_remove | 300 | 3.1589790 | 0.1244375 | 2,208,240 | 43,440 |
| 300 | current_remove | 300 | 1.6133335 | 0.2197290 | 1,124,640 | 115,080 |

At 300 entries the 300,000-hit sweep is 882.4282295→117.7901045 ms in this interpreted fixture. Hit and miss **allocation is unchanged at every population**, including the raw cells. Mutation allocation drops in the shown phases. The only observed median timing regression is 30-entry cold install: 0.0225005→0.024292 ms, +7.9620%; its allocation falls 16,680→13,488 B. All rows remain retained. Two cells per role on a shared host establish no stable or universal latency bound, native server gain, CPU percentage or 0.1 ms acceptance.

## Reproduction and authority

[measurements.jsonl](measurements.jsonl) retains one initial semantics row, all 72 phase rows and final checks. Raw phase clocks/counters/checksums, [execution.json](execution.json), [plan.json](plan.json), [summary.json](summary.json) and the exact renamed [program](probe.ocaml.txt) are retained byte-for-byte. The plan records the resolved OCaml 5.5.1 interpreter and selected Mtime binary hashes; this is a selected input pin, not a transitive environment lock. Parent perf_counter and child Mtime clock origins differ, so only their intervals are compared.

[current-locations.json](current-locations.json) uses the repository evidence-location schema to map ten original capture paths and digests from [recorded-capture-hashes.json](recorded-capture-hashes.json) to retained names. [capture-locations.json](capture-locations.json) preserves the exact former custom-schema file and its original nine records. Historical capture receipts and provenance retain their recorded heads and source hashes; [current-source-capture.json](current-source-capture.json) describes the later fixture repair separately. Original source snapshots and all local reports remain under `artifacts/runs/extreme-perf-20261026/`. The frozen summary keeps capture-time filenames; locate renamed captures through the sidecar. [reproduce.py](reproduce.py) refuses existing output directories:

```sh
python3 -B -E docs/evidence/performance-keeper-owner-index-20261027/reproduce.py \
  --repo . --baseline-ref f861e7c628ff5cfd504c7e85120c39a804a99c41 \
  --output artifacts/runs/keeper-owner-index-new-run
```

Keep new runs outside this retained bundle. Edited source needs fresh evidence. No new cache, tuning threshold, compatibility layer or validation bypass is introduced. The separate native path comparison uses f861 without this Map change; those results cannot be attributed to this candidate. Native Map effects, startup/TUI, real peer/broadcast/Add-on work, deployment and the overall goal remain open.
