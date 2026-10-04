# PR #41121 nested JSON validation — 2026-10-05

Response based on published head `4650e496523f97f306382b37e9f549506891ac1d`. The numeric validator now uses an explicit stack. Reverse-pushing children preserves its original depth-first, left-to-right first-error selection; unsafe integer and nonfinite messages remain unchanged. No depth limit or API acceptance restriction was added.

A parsed 12,000-level JSON array reproduced stack exhaustion in the actual API decoder → readings component path ([validator-red.log](validator-red.log), handle 78992 exit 1). The same data also exposed native pretty-print stack exhaustion in the whole panel's pre-existing raw-fields output ([panel-red.log](panel-red.log), handle 31990 exit 1 after the validator repair). Both the row and selected-event raw fields now catch only that native `RangeError` and display an explicit formatter-unavailable message. Other exceptions propagate. Parsed fields remain accepted; declared readings, navigation and original evidence stay usable.

The final regression traverses the real snapshot decoder and entire panel, checks the exact deeply nested declared reading, opens its selected event, and verifies original evidence and the raw-display fallback. Two additional cases verify first-error ordering across nested unsafe and nonfinite numbers. Existing ordinary values and numeric validation cases remain intact.

Prior validation before the compact-formatter followup: **31 tests in one matched suite PASS**, handle 96985 exit 0. The command also supplied `lane-inventory-panel.test.ts`, which does not exist on this older branch and contributed no tests. TypeScript and changed-file ESLint passed, handle 33164 exit 0. [checks.json](checks.json) records exact commands and source/log hashes. Final selected-event and ordering assertions extend the original RED regression without removing checks.

The initial missing-vitest attempt was setup failure, not RED; offline frozen installation succeeded. A 4,000-level exploratory case passed and is not represented as a failure. No browser, native, full regression, deployment or release proof is claimed. Raw logs retain their original bytes, including EOF whitespace.

## Compact formatter followup

The declared JSON reading also catches only native `RangeError`, reporting a distinct formatter-capacity reason rather than rejecting valid data as wrong-type. Other exceptions still propagate. An additional real decoder → whole-panel test selectively simulates a browser compact-serializer `RangeError` only for the parsed deep value and verifies both row and selected-event displays plus original evidence. Its temporary spy is always restored; the ordinary current-engine deep full-text test remains unchanged.

Final validation supersedes the prior count: **32 tests in one suite PASS**, handle 11938 exit 0; TypeScript and changed-file ESLint PASS, handle 61661 exit 0. Exact raw followup logs and refreshed source hashes are recorded in `checks.json`. No production-wide serializer patch, arbitrary nesting limit, or browser execution claim was added.
