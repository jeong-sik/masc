(rule
 (alias runtest-test_tui_fusion_owed_read)
 (deps test_tui_fusion_owed_read.py test_tui_fusion_recovery.py ../bin/masc_tui.exe)
 (action (run python3 %{dep:test_tui_fusion_owed_read.py} %{dep:../bin/masc_tui.exe})))

(alias (name runtest) (deps (alias runtest-test_tui_fusion_owed_read)))
