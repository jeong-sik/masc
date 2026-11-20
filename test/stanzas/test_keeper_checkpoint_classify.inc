; Keeper_checkpoint_store.classify_core_error pinning: a missing checkpoint
; is decided by the typed owned-file read before agent core runs, so the
; classifier has no Not_found arm.

(test
 (name test_keeper_checkpoint_classify)
 (modules test_keeper_checkpoint_classify)
 (libraries masc_test_deps))
