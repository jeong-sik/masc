(test
 (name test_skill_activations_broadcast)
 (modules test_skill_activations_broadcast)
 (libraries alcotest eio eio_main unix masc
  masc.fs_compat masc.keeper_registry masc_server masc_test_deps masc_workspace yojson))
