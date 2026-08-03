(test
 (name test_openapi_api_e2e)
 (modules test_openapi_api_e2e)
 (libraries alcotest masc_test_runtime yojson unix masc.server)
 (deps ../bin/main_eio.exe)
 (enabled_if (= %{env:MASC_E2E_TESTS=false} "true"))
 (action
  (setenv MASC_MAIN_EIO_EXE %{dep:../bin/main_eio.exe} (run %{test}))))
