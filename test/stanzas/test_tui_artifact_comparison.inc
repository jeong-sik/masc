(rule
 (alias runtest-test_tui_artifact_comparison)
 (deps test_tui_artifact_comparison.py test_tui_input_frame_pty.py
       test_tui_keyboard_input.py
       (glob_files test_tui_keyboard_*_pty.py)
       ../scripts/harness/perf/compare_tui_artifacts.py)
 (action (run python3 %{dep:test_tui_artifact_comparison.py})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_artifact_comparison)))
