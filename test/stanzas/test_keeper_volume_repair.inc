; RFC keeper-volume-filesystem-repair §3.3: the repair flow with its effects
; faked, the receipt, and the clone that never falls back to a data copy.
(test
 (name test_keeper_volume_repair)
 (modules test_keeper_volume_repair)
 (libraries alcotest masc masc.fs_compat eio eio_main yojson unix))
