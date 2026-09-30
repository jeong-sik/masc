(test
 (name test_keeper_attached_tools_lane_scope)
 (modules test_keeper_attached_tools_lane_scope)
 (libraries
  masc_test_deps
  masc.keeper_identity
  masc.mcp_client
  masc.masc_tool_blob_store
  masc.skill_config
  masc.skill_snapshot
  masc.skill_reference
  eio
  eio_main
  mirage-crypto-rng.unix))
