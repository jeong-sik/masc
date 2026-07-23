(test
 (name test_work_as_heartbeat)
 (modules test_work_as_heartbeat)
 (flags :standard -open Masc)
 (libraries masc masc.config alcotest eio_main unix))
