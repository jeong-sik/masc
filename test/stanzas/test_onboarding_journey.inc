(rule
 (alias runtest-test_onboarding_journey)
 (deps test_onboarding_journey.py ../scripts/install-runtime-setup.py)
 (action (run python3 %{dep:test_onboarding_journey.py})))

(alias
 (name runtest)
 (deps (alias runtest-test_onboarding_journey)))
