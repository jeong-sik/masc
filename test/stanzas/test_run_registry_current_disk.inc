(test
 (name test_run_registry_current_disk)
 (modules test_run_registry_current_disk)
 (libraries alcotest masc.run_registry_core fs_compat eio eio_main unix yojson))
