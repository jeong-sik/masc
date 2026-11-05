(test
 (name test_keeper_skill_activations_read)
 (modules test_keeper_skill_activations_read)
 (libraries alcotest eio eio_main unix masc masc.masc_types masc.masc_core
  masc.fs_compat masc.keeper_registry masc.runtime masc.skill_config
  masc.skill_reference masc.skill_snapshot masc.skill_snapshot_service
  masc_server masc_test_deps masc_workspace yojson))
