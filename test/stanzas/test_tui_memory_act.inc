; The Memory screen's writer act key: w arms the act the selected Keeper's writer row takes, a second w posts it, and the server's answer is drawn (RFC librarian-call-only-proposes §12.4).
(rule
 (alias runtest-test_tui_memory_act)
 (deps test_tui_memory_act.py test_tui_chat_owed_history.py tui_memory_health_rows.py test_tui_fusion_recovery.py ../bin/masc_tui.exe)
 (action (run python3 %{dep:test_tui_memory_act.py} %{dep:../bin/masc_tui.exe})))

(alias (name runtest) (deps (alias runtest-test_tui_memory_act)))
