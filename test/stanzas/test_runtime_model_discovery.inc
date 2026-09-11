(rule
 (alias runtest-test_runtime_model_discovery)
 (deps test_runtime_model_discovery.py ../bin/main_eio.exe)
 (action (run python3 %{dep:test_runtime_model_discovery.py} --binary %{dep:../bin/main_eio.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_runtime_model_discovery)))
(rule
 (alias runtest-test_runtime_model_discovery)
 (deps test_runtime_model_discovery.py ../bin/main_eio.exe)
 (action (run python3 %{dep:test_runtime_model_discovery.py} --binary %{dep:../bin/main_eio.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_runtime_model_discovery)))
