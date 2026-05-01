(test
 (name test_board_api_e2e)
 (modules test_board_api_e2e)
 (libraries alcotest unix)
 (deps ../bin/main_eio.exe)
 (enabled_if (= %{env:MASC_E2E_TESTS=false} "true")))
