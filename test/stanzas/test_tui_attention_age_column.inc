(rule
 (alias runtest-test_tui_attention_age_column)
 (deps
  test_tui_attention_age_column.py
  ../bin/masc_tui.exe
  tui_keyboard_harness.py)
 (action
  (run
   python3
   %{dep:test_tui_attention_age_column.py}
   %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_attention_age_column)))
