(rule
 (alias runtest-test_tui_observer_epoch)
 (deps test_tui_observer_epoch.py test_tui_waiting_event.py test_tui_fusion_recovery.py ../bin/masc_tui.exe)
 (action (run python3 %{dep:test_tui_observer_epoch.py} %{dep:../bin/masc_tui.exe})))

(alias (name runtest) (deps (alias runtest-test_tui_observer_epoch)))
