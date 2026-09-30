(rule
 (alias runtest-test_tui_remote_equipped_portrait)
 (deps test_tui_remote_equipped_portrait.py
       test_tui_keyboard_input.py
       test_tui_emblem_screen_pty.py
       test_keeper_portrait_http.exe
       ../bin/masc_tui.exe)
 (action
  (run python3 %{dep:test_tui_remote_equipped_portrait.py}
       %{dep:../bin/masc_tui.exe} %{dep:test_keeper_portrait_http.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_remote_equipped_portrait)))
