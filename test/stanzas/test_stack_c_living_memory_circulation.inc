(test
 (name test_stack_c_living_memory_circulation)
 (modules test_stack_c_living_memory_circulation)
 (libraries
  alcotest
  masc
  masc_server
  masc.agent_core
  masc.runtime
  masc.masc_tool_blob_store
  masc.tool_types
  masc_core
  masc_types
  masc_string_util
  fs_compat
  eio
  eio_main
  yojson
  unix))
