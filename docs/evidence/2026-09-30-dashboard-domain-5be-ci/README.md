# Dashboard domain: supplied CI and browser evidence

## Exact source and scope

- Source: `5be8d8fc35164915a3507898ce6fde117f379bb6`.
- [Run 36689441702](https://github.com/jeong-sik/masc/actions/runs/36689441702), [job 109802893661](https://github.com/jeong-sik/masc/actions/runs/36689441702/job/109802893661) (`Build and package dashboard`).
- This bundle preserves supplied completed job output and controlled Item browser fixture artifacts. Bundle preparation executed no tests, browser, native binary, build, or network requests.
- This evidence does not cover the newer `6e` composition, live ledger/workspace behavior, or all required checks for a current PR head.

## Measured test groups

Each row is a separate invocation recorded in the raw log.

| Invocation | Passed files | Passed tests |
| --- | ---: | ---: |
| activation | 9 | 444 |
| production_bundle_contract | 1 | 3 |
| requested | 9 | 133 |

The two Gate suites (`src/api/gate-keepers.test.ts`, `src/api/schemas/gate-keepers.test.ts`) and `src/store-normalizers.test.ts` occur in both activation and requested invocations. The group sum is **not a unique total of 580 tests**. No unique aggregate is asserted.

The actual selections below come from the job command/environment, rather than an intended selection. Per-file results, selector line references, and raw summaries are in [artifact-checks.json](artifact-checks.json).

### activation

- `src/components/keeper-config-panel.test.ts`
- `src/api/dashboard-keeper-config.test.ts`
- `src/api/dashboard.test.ts`
- `src/api/gate-keepers.test.ts`
- `src/api/schemas/gate-keepers.test.ts`
- `src/store-normalizers.test.ts`
- `src/components/fleet-health-panel.test.ts`
- `src/components/tool-monitor/tool-monitor-operations.test.ts`
- `src/components/tool-monitor/tool-monitor-reactivity.test.ts`

### production_bundle_contract

- `src/dashboard-bundle-preload.test.ts`

### requested

- `src/api/schemas/candle-observation.test.ts`
- `src/api/schemas/keeper-portrait.test.ts`
- `src/api/schemas/gate-keepers.test.ts`
- `src/api/gate-keepers.test.ts`
- `src/keeper-store-normalize.test.ts`
- `src/components/candle-economy.test.ts`
- `src/components/keeper-portrait.test.ts`
- `src/components/keeper-items-panel.test.ts`
- `src/store-normalizers.test.ts`

## Controlled browser fixture

The manifest identifies the production Item component in a controlled browser fixture with synthetic account and roster revisions. Chromium version: `149.0.7827.55`. The raw job reports `PASS (7 screens, 5 account reads)`.

- Five synthetic account requests: four successful responses and one intended failed request (request 4).
- Seven captures; all seven supplied PNG SHA-256 values match [manifest.json](manifest.json). PNG signatures and header dimensions were checked locally; no independent pixel review is claimed.
- The manifest records zero page errors. This does not mean zero connection failures: the raw log contains two readiness curl connection failures before the browser scenario.
- The fixture runs against loopback with synthetic data. These captures do not establish a live backend or current workspace A/B/A behavior.

| Supplied capture | Dimensions | Bytes |
| --- | ---: | ---: |
| [keeper-items-desktop.png](keeper-items-desktop.png) | 1280 × 1079 | 63717 |
| [keeper-items-mobile.png](keeper-items-mobile.png) | 360 × 1280 | 56301 |
| [keeper-items-loading.png](keeper-items-loading.png) | 1280 × 900 | 38233 |
| [keeper-items-free-purchase.png](keeper-items-free-purchase.png) | 1280 × 1079 | 64271 |
| [keeper-items-price-change.png](keeper-items-price-change.png) | 1280 × 1079 | 64282 |
| [keeper-items-unavailable.png](keeper-items-unavailable.png) | 1280 × 900 | 45179 |
| [keeper-items-recovered.png](keeper-items-recovered.png) | 1280 × 1127 | 64712 |

## Historical source import audit

The three original audit files are preserved without modification:

- [actual-946-dashboard-source-inventory.json](actual-946-dashboard-source-inventory.json): supplied nontruncated inventory of 1,593 `dashboard/src` Git blobs.
- [actual946-vs-local-source-delta.json](actual946-vs-local-source-delta.json): supplied actual946 tree `dcfeba9af2326899e8cfd54c284a845dd3ebf6ea` compared with local `a215894`.
- [actual946-diverged-import-mentions.json](actual946-diverged-import-mentions.json): textual pattern receipts for all 22 differing paths.

The entire local `dashboard/src` blob inventory was independently read with `git ls-tree` at immutable commit `a215894965a620af1ba80d6c464eb6e082e4e423`. Its 1,593 paths match the supplied remote inventory. Recomputed blob comparison confirms **22 different and 1,571 identical blobs**, and every supplied delta/mention receipt agrees with the corresponding blob IDs. Remote inventory was supplied by root, with no new remote fetch by this reviewer.

The textual pattern matches four of the 22 differing files. This is evidence for the specified pattern in those receipts, not a global import graph, absence of other dependencies, or a full current repository comparison. The historical actual946/local-a215 scope is distinct from the measured CI source `5be8d8fc…`.

## Artifact integrity and provenance

[ci-job.log.gz](ci-job.log.gz) losslessly preserves the complete supplied 165,538-byte, 1,316-line raw job log, including checkout and post-job cleanup. Raw SHA-256: `8fbab5eb12ffe76302cc309db4eab554a23def24ccf24acc402072cf9ffb6472`. Gzip has `mtime=0` and no original filename header; decompression was compared byte-for-byte with the input. ANSI escapes are retained in the stored log and were removed only for parsing result summaries.

The job reports browser artifact ID `11086562332` and uploaded zip SHA-256 `5b91a374e71e8f15970af114a13f588dfd10f6ac0865aafb362dfab7de7cf124`. The zip itself was not supplied, so that digest is reported from the job log, not independently checked against an archive.

[provenance.json](provenance.json) records inputs and scope. [artifact-checks.json](artifact-checks.json) records measured checks. [SHA256SUMS](SHA256SUMS) covers every other file in this directory. Publication payloads outside this bundle include Git blob hashes and base64 bytes; root chooses the publication parent. No source code is changed by this evidence bundle.
