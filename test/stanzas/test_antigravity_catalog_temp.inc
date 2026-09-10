(rule
 (alias runtest-test_antigravity_catalog_temp)
 (deps test_antigravity_catalog_temp.py ../bin/main_eio.exe)
 (action (run python3 %{dep:test_antigravity_catalog_temp.py} --binary %{dep:../bin/main_eio.exe})))
(alias (name runtest) (deps (alias runtest-test_antigravity_catalog_temp)))
