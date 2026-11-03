(test
 (name test_keeper_waiting_observer_scope)
 (modules test_keeper_waiting_observer_scope)
 (libraries masc masc_test_deps masc.server masc.auth masc.masc_core masc.masc_types
   masc.masc_eio_context masc.masc_goal masc.tool_types masc.masc_process masc.fs_compat
   alcotest bigstringaf eio eio.unix eio_main httpun unix yojson))
