(test
 (name test_keeper_waiting_observer_scope)
 (modules test_keeper_waiting_observer_scope)
 (libraries masc masc_test_deps masc.server masc.fs_compat
   alcotest bigstringaf eio eio_main httpun unix))
