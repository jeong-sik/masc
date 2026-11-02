(rule
 (alias runtest-test_tui_keeper_calls_signal)
 (deps test_tui_keeper_calls_signal.py test_tui_chat_owed_history.py test_tui_fusion_recovery.py ../bin/masc_tui.exe)
 (action (run python3 %{dep:test_tui_keeper_calls_signal.py} %{dep:../bin/masc_tui.exe})))

(alias (name runtest) (deps (alias runtest-test_tui_keeper_calls_signal)))
