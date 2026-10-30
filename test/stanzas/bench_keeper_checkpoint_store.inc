; Not a test: prints what the Keeper checkpoint store writes per tool round
; and reads per load against the history size (RFC-0476 L0). Run by hand from
; _build/default/test.

(executable
 (name bench_keeper_checkpoint_store)
 (modules bench_keeper_checkpoint_store)
 (libraries masc_test_deps base64))
