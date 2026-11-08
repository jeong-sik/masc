(test
 (name test_schedules_announce)
 (modules test_schedules_announce)
 (libraries alcotest eio eio_main unix masc masc.masc_schedule
  masc.fs_compat masc_server masc_test_deps masc_workspace yojson))
