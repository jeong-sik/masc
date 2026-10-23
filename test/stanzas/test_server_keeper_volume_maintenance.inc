; RFC keeper-volume-filesystem-repair §3.3: when the volume sweep starts a
; repair, with the lane and the fiber faked.
(test
 (name test_server_keeper_volume_maintenance)
 (modules test_server_keeper_volume_maintenance)
 (libraries alcotest masc masc.server yojson))
