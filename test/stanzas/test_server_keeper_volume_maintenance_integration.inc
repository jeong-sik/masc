; Runs one actual sweep against isolated images, Board storage and fake CLI.
(test
 (name test_server_keeper_volume_maintenance_integration)
 (modules test_server_keeper_volume_maintenance_integration)
 (libraries
  alcotest astring masc masc.server masc_test_deps
  masc.config_dir_resolver masc.fs_compat masc.masc_process masc.masc_workspace masc.masc_board
  eio eio.unix eio_main unix yojson mirage-crypto-rng.unix))
