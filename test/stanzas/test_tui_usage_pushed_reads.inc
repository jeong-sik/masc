(rule
 (alias runtest-test_tui_usage_pushed_reads)
 (deps test_tui_usage_pushed_reads.py test_tui_chat_owed_history.py test_tui_fusion_recovery.py ../bin/masc_tui.exe)
 (action (run python3 %{dep:test_tui_usage_pushed_reads.py} %{dep:../bin/masc_tui.exe})))

(alias (name runtest) (deps (alias runtest-test_tui_usage_pushed_reads)))
