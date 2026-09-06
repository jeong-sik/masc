(test
 (name test_posix_spawn_process_mgr)
 (modules test_posix_spawn_process_mgr)
 (libraries masc.masc_process masc_string_util eio eio.unix eio_main alcotest unix))
