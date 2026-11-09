(test
 (name test_server_skill_missing_on_disk)
 (modules test_server_skill_missing_on_disk)
 (libraries
  alcotest
  masc
  masc.agent_core.digest
  masc.keeper_registry
  masc.masc_types
  masc.skill_config
  masc.skill_reference
  masc.skill_snapshot
  masc.skill_snapshot_service
  masc.time_compat
  masc.time_codec
  masc_server
  yojson
  fs_compat
  unix))
