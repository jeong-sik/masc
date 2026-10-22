; RFC keeper-volume-filesystem-repair §3.1: ext4 superblock error state, read
; from the host image. The fixtures are real superblocks from 2026-10-22.
(test
 (name test_keeper_volume_filesystem)
 (modules test_keeper_volume_filesystem)
 (deps fixtures/ext4-superblock-errors.hex fixtures/ext4-superblock-clean.hex)
 (libraries alcotest masc unix yojson))
