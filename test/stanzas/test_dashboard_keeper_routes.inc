(test
 (name test_dashboard_keeper_routes)
 (modules test_dashboard_keeper_routes)
 (libraries masc_test_deps)
 (deps ../bin/main_eio.exe)
 (enabled_if (= %{env:MASC_E2E_TESTS=false} "true")))
