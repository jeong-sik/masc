(test
 (name test_keeper_event_queue_announce)
 (modules test_keeper_event_queue_announce)
 (libraries alcotest eio eio_main unix masc masc.fs_compat masc.masc_core masc.keeper_runtime masc_server))
