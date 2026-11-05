(test
 (name test_dashboard_runtime_probe_loop)
 (modules test_dashboard_runtime_probe_loop)
 (libraries alcotest eio eio_main eio.mock unix masc masc.fs_compat masc.masc_core masc_server
  yojson))
