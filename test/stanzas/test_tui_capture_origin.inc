(rule
 (alias runtest-test_tui_capture_origin)
 (deps test_tui_capture_origin.py ../scripts/capture-tui-ci-frames.py)
 (action (run python3 %{dep:test_tui_capture_origin.py})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_capture_origin)))
