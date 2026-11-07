; The command as the install script and the docs run it: the real executable.
(rule
 (alias runtest-test_browser_lane_setup_cli)
 (deps test_browser_lane_setup_cli.py ../bin/main_eio.exe)
 (action (run python3 %{dep:test_browser_lane_setup_cli.py} %{dep:../bin/main_eio.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_browser_lane_setup_cli)))
