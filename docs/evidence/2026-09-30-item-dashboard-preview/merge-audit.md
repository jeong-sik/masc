# Item merge audit

Source comparison used main `04256f2b1d` and preview parent
`758d271c4824e338106ec5e708abcd1e59114f2b`. This is a source and focused
frontend audit; no native build, native HTTP execution or installed proof.

1. Purchase: `Candle_shop.purchase` folds and validates the ledger inside its
   update callback. Duplicate ownership and insufficient funds refuse before
   an event is appended. Reviewed source only.
2. Equip: `Candle_balance.equip` refuses wrong-slot and unowned items.
   Default restoration changes only selection. Reviewed source only.
3. Account/portrait: HTTP route matching and the preview argument agree with
   their interfaces. Preview replaces one drawing slot and scopes cache/ETag
   to composed equipment. Native router scenario remains unexecuted.
4. Dashboard: Item API, account panel, portrait and economy suites passed
   30 tests in 4.70 seconds before this fix. Found a hidden preview failure:
   the generic badge fallback did not tell the operator that PNG loading failed.
   Preview-specific alert fallback and return-to-current recovery now pass
   25 affected-suite tests in 3.89 seconds; TypeScript passes.
5. TUI: the older dashboard branch still uses compact rendering for every
   outfit. Existing PR #40188 has the accessory-preserving renderer repair.
   Retain that repair when the separate TUI stack lands; do not infer the
   dashboard branch alone fixes this path.

No CI was requested. Browser capture remains sandbox-blocked. Source reviews
found no further P0–P2 in the preview failure/recovery change.
