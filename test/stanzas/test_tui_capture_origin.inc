(rule
 (alias runtest-test_tui_capture_origin)
 (deps test_tui_capture_origin.py ../scripts/capture-tui-ci-frames.py
  ../docs/evidence/tui-reading-validation-20261008/logs/primary-lists.log.gz
  ../docs/evidence/tui-reading-validation-20261008/screens-manifest.json)
 (action (run python3 %{dep:test_tui_capture_origin.py})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_capture_origin)))
