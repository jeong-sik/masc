(rule
 (alias runtest-test_tui_lane_stale_failure)
 (deps
  test_tui_lane_stale_failure.py
  ../bin/masc_tui.exe
  tui_keyboard_chat.py
  tui_keyboard_harness.py
  tui_keyboard_keepers.py
  tui_keyboard_observer.py
  tui_keyboard_runtime.py
  tui_keyboard_tools.py)
 (action
  (run python3 %{dep:test_tui_lane_stale_failure.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_lane_stale_failure)))
