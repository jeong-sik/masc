; Keeper_checkpoint_store.is_not_found_detail classifier
; regression (observed 334-retry loop on trace-1775487505102-6a347
; on 2026-04-12 — Eio.Io rendered form not recognized as Not_found)

(test
 (name test_keeper_checkpoint_classify)
 (modules test_keeper_checkpoint_classify)
 (libraries masc_test_deps))
