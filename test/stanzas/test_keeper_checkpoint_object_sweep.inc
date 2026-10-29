; RFC-0476 §3.6: the startup sweep keeps the checkpoint objects a root head
; reaches and removes the rest.

(test
 (name test_keeper_checkpoint_object_sweep)
 (modules test_keeper_checkpoint_object_sweep)
 (libraries masc_test_deps))
