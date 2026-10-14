(executable
 (name test_tui_keys_doc)
 (modules test_tui_keys_doc)
 (libraries masc_tui_keys_doc))

(rule
 (alias runtest-test_tui_keys_doc)
 (deps test_tui_keys_doc.exe
       ../docs/guides/TUI-KEYS.md)
 (action
  (run %{dep:test_tui_keys_doc.exe} %{dep:../docs/guides/TUI-KEYS.md})))

(alias
 (name runtest)
 (deps (alias runtest-test_tui_keys_doc)))
