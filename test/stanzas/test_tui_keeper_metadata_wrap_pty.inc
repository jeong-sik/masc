(rule
 (alias runtest-test_tui_keeper_metadata_wrap_pty)
 (deps
  tui_keyboard_approvals.py
  tui_keyboard_board.py
  tui_keyboard_browser.py
  tui_keyboard_chat.py
  tui_keyboard_clients.py
  tui_keyboard_context.py
  tui_keyboard_dashboard.py
  tui_keyboard_fusion.py
  tui_keyboard_harness.py
  tui_keyboard_keepers.py
  tui_keyboard_machines.py
  tui_keyboard_memory.py
  tui_keyboard_observer.py
  tui_keyboard_planning.py
  tui_keyboard_repositories.py
  tui_keyboard_resources.py
  tui_keyboard_runtime.py
  tui_keyboard_schedule.py
  tui_keyboard_startup.py
  tui_keyboard_terminal.py
  tui_keyboard_tools.py
  tui_keyboard_voice.py
  tui_keyboard_walk.py
  tui_keyboard_workspace.py
 test_tui_keeper_metadata_wrap_pty.py test_tui_keyboard_input.py ../bin/masc_tui.exe)
 (action
  (run python3 %{dep:test_tui_keeper_metadata_wrap_pty.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_keeper_metadata_wrap_pty)))
