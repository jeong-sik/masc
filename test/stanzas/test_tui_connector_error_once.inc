(rule
 (alias runtest-test_tui_connector_error_once)
 (deps
  test_tui_connector_error_once.py
  ../bin/masc_tui.exe
  tui_keyboard_chat.py
  tui_keyboard_harness.py
  tui_keyboard_observer.py
  tui_keyboard_tools.py)
 (action
  (run python3 %{dep:test_tui_connector_error_once.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_connector_error_once)))
