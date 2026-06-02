(test
 (name test_sse_storm_e2e)
 (modules test_sse_storm_e2e)
 (libraries alcotest yojson unix)
 (deps ../bin/main_eio.exe)
 (enabled_if (= %{env:MASC_E2E_TESTS=false} "true")))
