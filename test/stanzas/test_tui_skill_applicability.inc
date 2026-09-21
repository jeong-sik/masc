(rule
 (alias runtest-test_tui_skill_applicability)
 (deps test_tui_skill_applicability.py test_tui_keyboard_input.py
  test_keeper_task_skill_turn_exact.exe ../bin/masc_tui.exe)
 (action
  (run python3 %{dep:test_tui_skill_applicability.py}
   %{dep:../bin/masc_tui.exe} %{dep:test_keeper_task_skill_turn_exact.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_skill_applicability)))
