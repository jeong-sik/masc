(rule
 (alias runtest-test_tui_chat_portrait_pty)
 (deps test_tui_chat_portrait_pty.py
  tui_keyboard_chat.py
  tui_keyboard_harness.py
  tui_keyboard_observer.py
  tui_keyboard_tools.py
  ../bin/masc_tui.exe)
 (action
  (run python3 %{dep:test_tui_chat_portrait_pty.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_chat_portrait_pty)))
