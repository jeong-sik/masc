(test
 (name test_keeper_skill_activations_read)
 (modules test_keeper_skill_activations_read)
 (libraries alcotest eio eio_main unix masc masc.masc_types masc.masc_core
  masc.fs_compat masc.keeper_registry masc_server masc_test_deps masc_workspace yojson))
