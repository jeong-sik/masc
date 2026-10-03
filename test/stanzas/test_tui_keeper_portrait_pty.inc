(rule
 (alias runtest-test_tui_keeper_portrait_pty)
 (deps
  test_tui_keeper_portrait_pty.py
  ../bin/masc_tui.exe
  tui_keyboard_chat.py
  tui_keyboard_harness.py
  tui_keyboard_observer.py
  tui_keyboard_tools.py
  tui_keyboard_startup.py
  tui_keyboard_terminal.py)
 (action
  (run python3 %{dep:test_tui_keeper_portrait_pty.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_keeper_portrait_pty)))
