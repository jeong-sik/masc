(rule
 (alias runtest-test_browser_native_host)
 (deps test_browser_native_host.py ../bin/masc_browser_host.exe)
 (action (run python3 %{dep:test_browser_native_host.py} %{dep:../bin/masc_browser_host.exe})))

(rule
 (alias runtest-test_browser_bidi_host_link)
 (deps test_browser_bidi_host_link.py ../bin/masc_browser_host.exe)
 (action (run python3 %{dep:test_browser_bidi_host_link.py} %{dep:../bin/masc_browser_host.exe})))

; The command as the install script and the docs run it: the real executable.
(rule
 (alias runtest-test_browser_lane_setup_cli)
 (deps test_browser_lane_setup_cli.py ../bin/main_eio.exe ../bin/masc_browser_host.exe)
 (action (run python3 %{dep:test_browser_lane_setup_cli.py} %{dep:../bin/main_eio.exe}
          %{dep:../bin/masc_browser_host.exe})))

(alias
 (name runtest)
 (deps
  (alias runtest-test_browser_native_host)
  (alias runtest-test_browser_bidi_host_link)
  (alias runtest-test_browser_lane_setup_cli)))
