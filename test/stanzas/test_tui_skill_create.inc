(rule
 (alias runtest-test_tui_skill_create)
 (deps
  test_tui_skill_create.py
  ../bin/masc_tui.exe
  tui_keyboard_harness.py)
 (action
  (run python3 %{dep:test_tui_skill_create.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_skill_create)))
