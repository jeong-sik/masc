(test
 (name test_browser_activity)
 (modules test_browser_activity)
 (libraries alcotest eio_main eio yojson otoml masc.browser_lane
  masc.browser_configuration masc.time_compat))

(rule
 (alias runtest-test_stdio_browser_activity)
 (deps ../bin/main_stdio_eio.exe test_stdio_browser_activity.py
       (source_tree ../config/prompts))
 (action
  (setenv DUNE_SOURCEROOT %{workspace_root}
   (run python3 %{dep:test_stdio_browser_activity.py} %{dep:../bin/main_stdio_eio.exe}))))

(alias
 (name runtest)
 (deps (alias runtest-test_stdio_browser_activity)))

(rule
 (alias runtest-test_stdio_machine_activity)
 (deps ../bin/main_stdio_eio.exe test_stdio_machine_activity.py
       (source_tree ../config/prompts))
 (action
  (setenv DUNE_SOURCEROOT %{workspace_root}
   (run python3 %{dep:test_stdio_machine_activity.py} %{dep:../bin/main_stdio_eio.exe}))))

(alias
 (name runtest)
 (deps (alias runtest-test_stdio_machine_activity)))
