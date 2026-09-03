; RFC-0405. Pins the two things that differ between microVM runtimes — the
; argv and the parse — against the CLIs they were read from, so a spelling
; that drifts fails here rather than on every call of a live keeper.
(test
 (name test_keeper_microvm_backend)
 (modules test_keeper_microvm_backend)
 (libraries masc_test_deps))
