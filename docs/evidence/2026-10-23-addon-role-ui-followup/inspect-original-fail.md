# Independent source review: FAIL

Base: `70f438d054df3c0fe4eaf51853d4775cc42bab81`

Patch SHA256: `53a9b8747740ae6e853be958916c21265e610b3f372cd9368d5d697fb76a953f`

The exact four source hashes in the frozen manifest were verified before this record. The reviewer did not author these changes. This is source review only.

## P2: a presentation switch may select another worker

`selectable_overview_entries` (ML line 448) groups current entries and filters declarations only in Flow. `toggle_flow` (line 562) keeps the former index and merely clamps it. New role grouping can put an unresolved declaration before or between workers: Summary `[D(memory), B(browser), A(analysis)]`, selected B at index 1, becomes Flow `[B, A]`, still index 1, so A becomes the action target. `selected_instance` and `open_actions`/observe/detach consume the new target.

`toggle_history` (line 467) also saves a Flow cursor against unfiltered `overview_entries`; the D handler in `bin/masc_tui.ml:26377` directly changes presentation and reinterprets the same index. Fixing f alone leaves both paths. Capture the current exact anchor from the currently selectable projection, remap through the new projection, and leave selection absent when that original is hidden or replaced. A meaningful regression should check actual `selected_instance` and submitted action target across f/D/h transitions with interleaved unresolved declarations; no wording, row-order or snapshot test is needed.

## Other source findings

Current role trust now requires complete observation, unique ID-or-path claim, exact ID-and-path, parsed origin and no declaration issues. Manual workers use their original package role; partial ownership is unverified. Strict optional category decoding and ML/MLI fields agree. Direct record producers were searched; no missing new field was found. Retained run grouping and original worker metadata remain independent.

Headers are not selectable entries, and overview rendering/selection use the same role list. The selected item begins its logical window, but arbitrary narrow viewport visibility remains unverified because wrapped diagnostics/headings precede the list and the overlay clips by budget. No compiled, executed, CI, installed or visible-terminal result is claimed.
