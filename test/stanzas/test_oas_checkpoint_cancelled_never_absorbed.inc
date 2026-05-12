; iter 67 M-2.c — OCaml-side CancelledNeverAbsorbed regression guard
; (KeeperOASAdvanced.tla bug-model loop closer).
; Pure source-text inspection; no MASC_BASE_PATH, no project libs.

(test
 (name test_oas_checkpoint_cancelled_never_absorbed)
 (modules test_oas_checkpoint_cancelled_never_absorbed)
 (deps ../lib/keeper/keeper_oas_checkpoint.ml))
