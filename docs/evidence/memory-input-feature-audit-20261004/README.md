# Memory input feature audit

This audit covers the feature introduced by PR #41023. The source hashes in manifest.json identify the repaired files before their commit.

## Reproduced failures and repairs

1. A truncated newest JSONL row was silently skipped by the turn-record endpoint, allowing an older input to be labeled last. The endpoint now uses Server_keeper_turn_records.read, which reads physical rows strictly and preserves skipped counts and storage errors.
2. A Memory health refresh could change the selected Keeper when fact rankings changed. The existing binary fixture PTY captured alpha before refresh and beta after refresh without navigation. Snapshot application now restores the selected Keeper by identity, with a clamped fallback for removal.
3. Runtime estimates can appear in request-scoped token records. The input summary now calls values recorded and explicitly says runtime estimates may be included.

The new PTY tests also incorrectly awaited a full redraw after requesting unchanged dimensions. They now acknowledge a distinct intermediate geometry before recapturing the intended size.

## Executed evidence

- aggregation-tests.log: 3 native tests passed against the current aggregation source.
- storage-boundary-tests.log: 3 native tests passed using real temporary dated JSONL files, the production API reader and the actual Memory decoder. Cases cover a truncated newest record, invalid storage file type and a valid input summary.
- live-page-summary.log: authenticated read-only production API response decoded by the current Memory aggregate. This single captured page had 50 records, 18 token samples and no request-byte samples. The raw response and credential are not committed.
- selection-baseline-frames.json and selection-drift-baseline.png: actual existing-binary PTY screen cells with synthetic HTTP data. The PNG exports those cells without preserving ANSI colors. Binary identity is its recorded SHA-256; source revision is not inferred.

Native tests used isolated OCaml 5.5.1 compilation of the changed components with existing dependency objects. No local Dune or full product build was run. These tests establish the storage/aggregation boundary, not a new candidate server or TUI binary. The new render/selection and full candidate PTY tests remain unexecuted. Nothing was installed or deployed.
