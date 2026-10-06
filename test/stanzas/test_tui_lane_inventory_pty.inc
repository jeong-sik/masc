(rule
 (alias runtest-test_tui_lane_inventory_pty)
 (deps
  test_tui_lane_inventory_pty.py
  ../bin/masc_tui.exe
  tui_keyboard_harness.py
  tui_keyboard_keepers.py
  tui_keyboard_runtime.py)
 (action
  (run python3 %{dep:test_tui_lane_inventory_pty.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_lane_inventory_pty)))
