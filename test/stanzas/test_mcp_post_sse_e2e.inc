(test
 (name test_mcp_post_sse_e2e)
 (modules test_mcp_post_sse_e2e)
 (libraries alcotest masc_test_runtime masc.string_util yojson unix)
 (deps ../bin/main_eio.exe)
 (enabled_if (= %{env:MASC_E2E_TESTS=false} "true"))
 (action
  (setenv MASC_MAIN_EIO_EXE %{dep:../bin/main_eio.exe} (run %{test}))))
