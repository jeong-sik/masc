# Collaboration-preserving Chat candidate

The standalone Chat source a28e817 passed six native target suites (149 tests) and its macOS ARM release job. Its binary, four companion files and bundled-runtime archive match the paired dashboard release manifest. That source omits installed aad94 Fusion context, durable-result and Gate changes, so it was downloaded but not deployed. The release workflow as a whole is not claimed complete here.

Candidate PR #35581, 4324764e959a5ff8b265b292e5bab9f68e550313, starts from current collaboration parent f81284ca4de88abc1614be712e094178c8de23ea and applies the reviewed Chat execution/index/output/manifest commits. The installed Fusion/Gate/Board implementations are preserved by direct source comparison and independent review. Six UI suites/203 cases, Dashboard typecheck, 13 OCaml parse-only checks and changed-line DET pass. New native Test34705063187 and Release34705064645 are requested; neither is counted as passed in this receipt.

The installed browser probe now locates its exact execution row before requiring a snapshot child, scrolls that row into view to trigger historical lookup, then waits for the snapshot. Three synthetic Chromium locator cases passed: offscreen lazy loading, duplicate identity rejection and unrelated snapshot rejection. These are synthetic probe checks, not installed Dashboard acceptance.

Runtime aad94 remains installed and healthy at this observation. Actual Chat desktop/mobile original-byte and diff reconstruction acceptance, and native Gate continuation acceptance, remain open.

Independent Board/Fusion evidence lookup also now binds the actually loaded store directory rather than a later environment value. PR35536 head25847ebc has native Test34704870980 requested. General Board writer paths still use environment-derived paths; this work does not claim general multi-workspace write isolation.
