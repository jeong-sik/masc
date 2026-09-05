; Filesystem-only: writes the binary's embedded config assets into a temp dir.
; No workspace, no server, no network.

(test
 (name test_config_root_embedded_seed)
 (modules test_config_root_embedded_seed)
 (action (run %{test}))
 (libraries masc_test_deps))
