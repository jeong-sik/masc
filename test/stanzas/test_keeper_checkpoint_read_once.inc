; What the checkpoint store reads from the canonical file, and when a summary
; or an exact snapshot answers without reading or decoding it.

(test
 (name test_keeper_checkpoint_read_once)
 (modules test_keeper_checkpoint_read_once)
 (libraries masc_test_deps masc.keeper_checkpoint_ref digestif))
