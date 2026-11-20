; No pipefail or pipefail-sourced shell script may pipe into `head`,
; which closes stdin early and triggers SIGPIPE (141) on long inputs (#49428).
(rule
 (alias runtest-test_scripts_pipefail_head)
 (deps
  test_scripts_pipefail_head.py
  (source_tree %{workspace_root}/scripts)
  (source_tree %{workspace_root}/dashboard/scripts))
 (action
  (run python3 %{dep:test_scripts_pipefail_head.py})))

(alias
 (name runtest)
 (deps (alias runtest-test_scripts_pipefail_head)))
