# Vision artifact comparison

Run: https://github.com/jeong-sik/masc/actions/runs/36580779720
Harness: `4571ce970e81c76f887891074ccb5871dc855b72`. Three alternating 90-second pairs on one runner.

**Complete measurement; improvement not established under this workload.**

Each window contains 203 verified operations (40 frame stores, 41 new kept stores, 41 repeat stores, 41 kept loads and 40 frame loads). Raw operation counts and nearest-rank percentiles were independently recomputed. Every sample falls inside both nonempty, zero-loss trace windows. All 18 child process receipts show exit 0 and reaped=true.

| Pair | Source | Frame store p50/p95 ms | Kept new p50/p95 ms | Load kept p50/p95 ms | Scheduler p99/max ms |
|---|---|---|---|---|---|
| 1 | before | 3.9871/5.8138 | 0.9410/1.2829 | 0.2630/0.2949 | 0.0839/1.6849 |
| 1 | after | 4.0379/5.5571 | 1.0931/1.2670 | 0.2940/0.3400 | 0.0839/1.6060 |
| 2 | after | 4.0748/5.1582 | 1.0700/1.3621 | 0.3090/0.3388 | 0.0839/1.5349 |
| 2 | before | 3.9251/6.3999 | 0.9511/2.3632 | 0.2601/0.2942 | 0.0839/1.2298 |
| 3 | before | 3.9148/4.9188 | 0.9410/1.2801 | 0.2630/0.3040 | 0.0839/1.3988 |
| 3 | after | 4.1211/6.1030 | 1.0788/3.0220 | 0.3011/0.3369 | 0.0839/1.6429 |

## Scope and limitations

The exact before/after sources are `13cd318566ff2cfea423ca1a08dc92bc1522b2aa` and `6ad482b39bb2cab3e0305086b5ecd65c7dff854a`, a direct parent/child pair for #39766. The same measurement driver is copied into both trees. Receipts record source labels and binary hashes; this is an instrumented library experiment, not installed server identity.

Load measurements use the real artifact load followed by an intentionally invalid media type, so no model request is needed. Product-call timings exclude verification reads. Scheduler/tracer observations still include fixture reads, verification and retention checks. Timing uses wall-clock timestamps; no host-load series was retained. The artifact contains a fixture inventory hash, but not all generated fixture bytes or build stdout. These limits prevent stronger causal or production claims.

No cancellation acceptance claim: #39774 and the remaining RFC section 7.5 syscall/CPU inventory remain separate obligations. Task-611 and #25893 remain open.

## Provenance

Actions artifact `11039947499`, original ZIP SHA-256 `5b0a725e263145f76b621114990d1a05bf810432e04e5181f906c25c6d7191a8`. The archive here repackages the downloaded raw directory and has its own checksum.

Fixture inventory SHA-256: `8cc0966587509023080fcfc7d7fb7633b78b0c7ae4633253088ea3000157e7b9`.

The older run `36579159565` was cancelled after the timing fix and is excluded.
