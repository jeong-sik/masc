# PR #41182 parent integration — 2026-10-05

Original head `ebe561e53aaa922b10c0041db785b6bc66d3bcba` with real pending merge of published parent #41180 `ac57271cbab3533766530473be47697c43f73bad`. Fresh REST omitted the stack key; membership is unknown. The original approval applies only to the original head.

One conflict in `overview/runtime-stats.ts` was resolved by composing the parent's broader usage-reporting providers (including configured HTTP usage and Antigravity), USD display and CLI-only login controls with this PR's workspace-stamped metrics, usage and login state. The usage effect uses the same broader provider predicate while retaining authority and catalog dependencies. The parent provider labels and test IDs remain. The child layout-effect request retirement still allows the first login click and rejects prior-account callbacks. Auto-merged tests preserve both scopes. No unrelated production changes were made; the fragment now cites this PR.

## Actual integrated checks

- Offline frozen dependency installation: PASS, handle 13905; no dependency manifest changes.
- Seven focused Web suites: 210 tests PASS, handle 87958. They cover Overview usage/metrics, workspace observation races and login, Config probe, shared catalog/workspace resources, Runtime editor and Settings consumers.
- TypeScript `tsc --noEmit`: PASS; changed-source/test ESLint: PASS, handle 21894. Both logs are empty successful output.

Exact commands and raw log hashes are in [checks.json](checks.json). All logs retain captured bytes and are explicitly tracked. No source changes occurred during execution.

Native `bin/`, `lib/`, and `test/` are byte-identical to the merged parent, so no native build or PTY was repeated. Earlier 62-test and eight-browser-check artifacts remain historical; no new browser execution, full suite, backend/provider execution, deployment or RC claim is made here.
