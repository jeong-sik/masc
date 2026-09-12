Inline tool descriptions
========================

Inventory cards now expose an accessible expand/collapse button, keeping the exact canonical description in the same card. The backend inventory producer returns schema.description instead of the 120-character help summary. Help summary contracts elsewhere remain unchanged.

Validation
----------

- tsc --noEmit passed.
- InventoryRow and VirtualList focused tests: 31 passed.
- Both changed OCaml files passed parse-only checks; no local build.
- A fresh 390 x 844 browser verified keyboard Enter expansion, Space collapse, pointer expansion and exact full text. Desktop proof is also included.
- In the active virtualized inventory, the expanded card grew from 217.22 px to 261.19 px. The next row began at the expanded card bottom (553.16 px), with no overlap.

Evidence scope
--------------

The current API receipt uses actual backend 83afd78483 and demonstrates that its inventory still truncates the description before the browser receives it. It does not prove the corrected producer is deployed. The screenshots and source-fixture receipt use the actual read-only API response with only masc_board_list.description replaced by its exact canonical config/tools/masc_board_list.toml description. This tests full-description UI behavior, not the new backend binary. Actual API-to-UI acceptance awaits CI and a candidate containing the producer correction.

The Vite preview composed this feature with the independent PR #35377 null-path fix (config-resolution-panel.ts and dashboard-execution.ts from 7bbb65db2d). That preview-only dependency is excluded from the feature commit. All remote mutations were blocked by the browser probe.
