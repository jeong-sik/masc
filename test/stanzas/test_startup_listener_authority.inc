(rule
 (alias runtest-test_startup_listener_authority)
 (deps test_startup_listener_authority.py ../bin/main_eio.exe
  ../scripts/fixtures/release-evidence/runtime.toml)
 (action (run python3 %{dep:test_startup_listener_authority.py} --binary %{dep:../bin/main_eio.exe})))
