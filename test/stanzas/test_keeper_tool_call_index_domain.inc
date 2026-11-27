(test
 (name test_keeper_tool_call_index_domain)
 (modules test_keeper_tool_call_index_domain)
 (libraries
  alcotest
  dated_jsonl
  eio
  eio_main
  masc.fs_compat
  masc.masc_core
  masc.keeper_tool_call_index
  sqlite3
  unix
  yojson))
