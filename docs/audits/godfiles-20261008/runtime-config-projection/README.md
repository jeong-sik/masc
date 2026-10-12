# Runtime config projection — #42308

Canonical immutable config data and pure source identity, receipt/assignment codecs and startup/stale-registry diagnostics now belong to the private `Runtime_config_projection` module. Runtime includes the canonical definitions and retains acquisition, file locks/writes, clocks, materialization and Atomic publication/getters. The public Runtime MLI is byte-identical to the base.

Runtime shrank from 4154 to 3718 lines; the owner has 440 lines. Remaining storage, publication, cache and configuration policies require semantic audit. All 171 campaign candidates remain open.

The focused build and three existing runtime TOML gate cases passed at code head `208da407ccdb8560515ec9a4a0e5f7e144479606`; run `TSNDC2DJ`. A subsequent change only clarified a moved comment. Current source hashes therefore include that comment correction, while compiled output hashes identify the actual earlier build. See [checks.json](checks.json), [test.output](test.output), [source.sha256](source.sha256) and [compiled-outputs.sha256](compiled-outputs.sha256).

Case 46 checks exact config save and stale-source refusal; case 57 checks assignment isolation/recovery with a local HTTP fixture; case 75 checks combined degradation JSON and its health-summary consumer. Other cases were skipped. No external provider call, live Keeper, installed/deployed binary, visible UI or full CI was verified. Initial redundant manifest type constraints failed to compile; the final direct include compiled successfully.

Before the comment correction, the extracted blocks matched the base apart from imports/include and EOF normalization, and the entire retained root matched the base mechanically. Independent source review passed that code head with one comment P3, now corrected. Final complete-diff reviews and formal GitHub approval remain distinct.
