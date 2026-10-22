; RFC keeper-volume-filesystem-repair §3.2: the server's last read of each
; image-backed Keeper volume. masc.server links the maintenance sweep that
; feeds it.
(test
 (name test_keeper_volume_filesystem_watch)
 (modules test_keeper_volume_filesystem_watch)
 (libraries alcotest masc masc.server yojson))
