(test
 (name test_native_query_observer_scope)
 (modules test_native_query_observer_scope)
 (libraries masc masc_test_deps masc.server masc.fs_compat
   alcotest bigstringaf eio eio_main httpun unix))
