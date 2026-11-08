(test
 (name test_provider_rest_announce)
 (modules test_provider_rest_announce)
 (libraries alcotest eio eio_main unix masc masc.fs_compat masc.masc_core masc.runtime
  masc_server masc_test_deps))
