(test
 (name test_sse_storm_e2e)
 (modules test_sse_storm_e2e)
 (libraries masc masc.auth masc.masc_types masc.runtime alcotest masc_test_runtime yojson unix)
 (deps ../bin/main_eio.exe)
 (enabled_if (= %{env:MASC_E2E_TESTS=false} "true"))
 (action
  (setenv MASC_MAIN_EIO_EXE %{dep:../bin/main_eio.exe} (run %{test}))))
