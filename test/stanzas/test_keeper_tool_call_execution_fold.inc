(test
 (name test_keeper_tool_call_execution_fold)
 (modules test_keeper_tool_call_execution_fold)
 (libraries
  alcotest
  unix
  yojson
  masc.fs_compat
  masc.dated_jsonl
  masc.keeper_tool_call_index))
