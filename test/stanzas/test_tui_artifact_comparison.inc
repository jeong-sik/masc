(rule
 (alias runtest-test_tui_artifact_comparison)
 (deps test_tui_artifact_comparison.py ../scripts/harness/perf/compare_tui_artifacts.py)
 (action (run python3 %{dep:test_tui_artifact_comparison.py})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_artifact_comparison)))
