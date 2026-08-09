; Keeper_checkpoint_store.classify_core_error pinning after RFC-0089 G4
; (#15514 sibling): ENOENT detection moved to OS boundary via
; Agent_core.Checkpoint_store.exists, classifier has no Not_found arm.

(test
 (name test_keeper_checkpoint_classify)
 (modules test_keeper_checkpoint_classify)
 (libraries masc_test_deps))
