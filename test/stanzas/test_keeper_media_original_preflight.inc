(test
 (name test_keeper_media_original_preflight)
 (modules test_keeper_media_original_preflight)
 (libraries masc_test_deps)
 (deps ../bin/deployment_preflight_helper.exe)
 (action (run %{test} %{dep:../bin/deployment_preflight_helper.exe})))
