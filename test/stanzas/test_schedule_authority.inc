(test
 (name test_schedule_authority)
 (modules test_schedule_authority)
 (libraries
  alcotest
  eio
  eio_main
  fs_compat
  masc_backend
  masc_core
  masc_workspace
  masc_schedule
  dated_jsonl
  unix
  yojson))
