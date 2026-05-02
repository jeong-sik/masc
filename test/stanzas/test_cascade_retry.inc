(executable
 (name test_cascade_retry)
 (modules test_cascade_retry)
 (libraries
  masc_mcp
  alcotest
  eio_main))

(rule
 (alias runtest)
 (action
  (run %{exe:test_cascade_retry.exe})))
