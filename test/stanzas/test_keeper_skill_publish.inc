; Keeper Skill publication through the server-installed editor hook

(test
 (name test_keeper_skill_publish)
 (modules test_keeper_skill_publish)
 (libraries
  masc_test_deps
  masc_server
  masc.skill_config
  masc.skill_reference
  masc.skill_snapshot
  masc.skill_snapshot_service))
