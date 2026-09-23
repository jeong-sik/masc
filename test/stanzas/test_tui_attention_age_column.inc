(rule
 (alias runtest-test_tui_attention_age_column)
 (deps
  test_tui_attention_age_column.py
  test_tui_keyboard_input.py
  ../bin/masc_tui.exe)
 (action
  (run
   python3
   %{dep:test_tui_attention_age_column.py}
   %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_attention_age_column)))
