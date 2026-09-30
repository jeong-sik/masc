(rule
 (alias runtest-test_tui_artifact_comparison)
 (deps
  test_tui_artifact_comparison.py
  test_tui_input_frame_pty.py
  (glob_files test_tui_keyboard_*_pty.py)
  ../scripts/harness/perf/compare_tui_artifacts.py
  ../scripts/harness/perf/linux_probe_artifact.py
  tui_keyboard_harness.py
  tui_keyboard_keepers.py
  tui_keyboard_runtime.py)
 (action (run python3 %{dep:test_tui_artifact_comparison.py})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_artifact_comparison)))
