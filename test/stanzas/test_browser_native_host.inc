(rule
 (alias runtest-test_browser_native_host)
 (deps test_browser_native_host.py ../bin/masc_browser_host.exe)
 (action (run python3 %{dep:test_browser_native_host.py} %{dep:../bin/masc_browser_host.exe})))

(rule
 (alias runtest-test_browser_bidi_host_link)
 (deps test_browser_bidi_host_link.py ../bin/masc_browser_host.exe)
 (action (run python3 %{dep:test_browser_bidi_host_link.py} %{dep:../bin/masc_browser_host.exe})))

(alias
 (name runtest)
 (deps
  (alias runtest-test_browser_native_host)
  (alias runtest-test_browser_bidi_host_link)))
