(test
 (name test_keeper_compaction)
 (modules test_keeper_compaction)
 (libraries
  masc
  masc_server
  alcotest
  masc.agent_core
  fs_compat
  masc_types
  masc_core
  masc_string_util
  masc.masc_tool_blob_store
  masc.runtime
  eio
  eio_main
  sqlite3
  unix
  yojson))
