(test
 (name test_runtime_metrics_announce)
 (modules test_runtime_metrics_announce)
 (libraries alcotest eio eio_main eio.mock unix masc masc.fs_compat masc.masc_core masc_server
  yojson))
