(rule
 (alias runtest-test_tui_librarian_context_review)
 (deps test_tui_librarian_context_review.py test_tui_keyboard_input.py
  test_keeper_librarian_context_review.exe ../bin/masc_tui.exe
  (source_tree ../config/prompts))
 (action
  (run python3 %{dep:test_tui_librarian_context_review.py}
   %{dep:../bin/masc_tui.exe} %{dep:test_keeper_librarian_context_review.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_librarian_context_review)))
