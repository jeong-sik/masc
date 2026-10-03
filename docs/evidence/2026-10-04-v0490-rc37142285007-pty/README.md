# Current-candidate TUI fixture repairs

[Full RC37142285007](https://github.com/jeong-sik/masc/actions/runs/37142285007) at e4afdce8f0c4ba4cf02e4326ba423c4fe2207339 completed with compile and four-platform installation success, but five Python targets failed. Native PDF verification passed21/21; no PDF implementation or budget was changed.

This change addresses four of those targets; #41043/#41045 repair runtime-lane editing separately:

- A tuple health fixture is rewritten to the local workspace by the harness. Return raw JSON to actually exercise foreign workspace withdrawal; the existing held-response, account recovery and late-response assertions remain.
- Retrying under an unread roster may repeat the same error. Follow retry with real cursor movement to observe processed input, then assert the unavailable error, absent money/ownership and no new Item account request.
- ANSI clear-screen is an output escape, not an input command. A real terminal resize requests the complete Resource frame and checks its current B revision, retaining all late-A rejection and superseding-B logic.
- Info's four-row icon at20px cell height is80px, while native fixture PNGs are160px. Advertise40px-high cells to compare the exact160px icon pixels without scaling or relaxing equality.

Previously approved Ask POST-only admission/completion and stronger Candle/late-balance assertions are integrated selectively. GitHub stream recovery navigates explicitly to Keepers after authority withdrawal already returned to the list; stale-stream and exact-login-count checks remain.

## Executed evidence

The final four diagnostic groups all passed on the existing e4 macOS ARM64 native binary (SHA25664ea20854e47c3a5883c717303de468cbc7ed7b811b8fcea815f263ee8bc41d6). Its embedded commit was checked. The Item authority group executes its full entrypoint, including partial-roster coverage. Resource exercises both held initialization and held read. Remote portrait uses real e4 Linux purchase/equip receipts from the failed RC and keeps exact decoded RGBA equality; the saved native and terminal manifests bind the two platforms' evidence.

The full keeper-portrait entrypoint passed16scenarios. Final source digests for all four changed files are in manifest.json and match after the scoped run. Scoped runner markers, results, raw artifact hashes, portrait log and before/equipped PNGs are retained here. Temporary raw terminal captures remain under /tmp/masc-rc37142285007-final-scoped-20261004.

## Remaining scope

Full remote-workspace execution progressed beyond Resource and Ask but exposed later failures. A downstream diagnostic census has eight failed cases and two passes; its results are retained and tracked under #41029. GitHub stream recovery passed after its navigation repair. Chat refusal width, queue projection, scoped roster setup, staged-media exit navigation, schedule title and identity-chain projection still require follow-up. No case was removed or skipped in the official target.

This is existing-native-binary fixture evidence, not a new PR binary, all-target Linux verification, a successful Full RC or release publication. The two native fixture platforms, partial diagnostic groups and full16scenario target remain distinct. Python AST, diff and changelog checks passed. Final independent review is requested; author/source inspection and runtime evidence do not establish independent approval.
