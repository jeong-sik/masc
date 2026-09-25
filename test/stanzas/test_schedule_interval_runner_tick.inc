; Schedule interval: create and modify refuse an interval shorter than the
; runner tick; load accepts any positive interval

(test
 (name test_schedule_interval_runner_tick)
 (modules test_schedule_interval_runner_tick)
 (libraries
  alcotest
  eio
  eio_main
  fs_compat
  masc_core
  masc_test_deps
  masc_workspace
  masc_schedule
  yojson))
