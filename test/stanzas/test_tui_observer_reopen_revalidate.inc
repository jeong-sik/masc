(rule
 (alias runtest-test_tui_observer_reopen_revalidate)
 (deps test_tui_observer_reopen_revalidate.py ../bin/masc_tui.exe)
 (action (run python3 %{dep:test_tui_observer_reopen_revalidate.py} %{dep:../bin/masc_tui.exe})))

(alias (name runtest) (deps (alias runtest-test_tui_observer_reopen_revalidate)))
