(rule
 (alias runtest-test_tui_context_catalog_scope)
 (deps test_tui_context_catalog_scope.py tui_keyboard_context.py
       tui_keyboard_runtime.py tui_keyboard_harness.py ../bin/masc_tui.exe)
 (action (run python3 %{dep:test_tui_context_catalog_scope.py} %{dep:../bin/masc_tui.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_context_catalog_scope)))
