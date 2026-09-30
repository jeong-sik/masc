(rule
 (alias runtest-test_capture_dashboard_ci_frames)
 (deps test_capture_dashboard_ci_frames.py ../scripts/capture-dashboard-ci-frames.py)
 (action (run python3 %{dep:test_capture_dashboard_ci_frames.py})))

(alias
 (name runtest)
 (deps (alias runtest-test_capture_dashboard_ci_frames)))
