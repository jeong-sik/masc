(rule
 (alias runtest-test_lane_addon_orphan_body_startup)
 (deps ../bin/main_eio.exe ../bin/main_stdio_eio.exe test_lane_addon_orphan_body_startup.py
       (source_tree ../config/prompts))
 (action
  (setenv DUNE_SOURCEROOT %{workspace_root}
   (run python3 %{dep:test_lane_addon_orphan_body_startup.py}
    %{dep:../bin/main_eio.exe} %{dep:../bin/main_stdio_eio.exe}))))

(alias
 (name runtest)
 (deps (alias runtest-test_lane_addon_orphan_body_startup)))
