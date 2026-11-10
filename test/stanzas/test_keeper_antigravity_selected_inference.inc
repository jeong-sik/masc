(test
 (name test_keeper_antigravity_selected_inference)
 (modules test_keeper_antigravity_selected_inference)
 ; An Antigravity turn installs a read hook beside the running MASC binary
 ; (runtime_antigravity_home.ml, prepare_read_hook: it looks for
 ; masc-antigravity-path-hook in the directory of Sys.executable_name and
 ; fails the turn with Settings_write_failed when it is missing). The sibling
 ; Antigravity suites declare this dep; without it this suite reaches
 ; pre_dispatch_failed before any child starts.
 (deps masc-antigravity-path-hook (source_tree %{workspace_root}/config/prompts))
 (libraries masc masc_test_deps))
