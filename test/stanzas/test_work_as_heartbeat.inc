(test
 (name test_work_as_heartbeat)
 (modules test_work_as_heartbeat)
 (flags :standard -open Masc)
 (libraries masc masc.config masc.telemetry_unified alcotest eio_main unix))
