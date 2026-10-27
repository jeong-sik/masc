(test
 (name test_execute_shell_host_admission)
 (modules test_execute_shell_host_admission)
 (libraries
  masc_test_deps
  masc
  masc.keeper_tooling
  masc.masc_exec
  masc.masc_core
  masc.masc_process
  alcotest
  eio
  eio_main
  unix
  yojson))
