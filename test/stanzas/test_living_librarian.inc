(test
 (name test_living_librarian)
 (modules test_living_librarian)
 (libraries
  alcotest
  masc
  masc.agent_core
  masc_core
  masc_types
  masc_string_util
  fs_compat
  eio
  eio_main
  yojson
  unix))
