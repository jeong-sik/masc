(test
 (name test_server_schedule_run_watch)
 (modules test_server_schedule_run_watch)
 (libraries alcotest unix yojson masc masc.server masc.config_dir_resolver
   masc_test_deps masc_schedule eio_main))
