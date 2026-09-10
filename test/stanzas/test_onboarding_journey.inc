(rule
 (alias runtest-test_onboarding_journey)
 (deps test_onboarding_journey.py ../scripts/install-runtime-setup.py ../bin/main_eio.exe)
 (action (run python3 %{dep:test_onboarding_journey.py} --binary %{dep:../bin/main_eio.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_onboarding_journey)))
