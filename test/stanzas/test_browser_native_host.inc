(rule
 (alias runtest-test_browser_native_host)
 (deps test_browser_native_host.py ../bin/masc_browser_host.exe)
 (action (run python3 %{dep:test_browser_native_host.py} %{dep:../bin/masc_browser_host.exe})))

(rule
 (alias runtest-test_browser_host_install)
 (deps test_browser_host_install.py ../connectors/browser/install-host.sh)
 (action (run python3 %{dep:test_browser_host_install.py} %{dep:../connectors/browser/install-host.sh})))

(alias
 (name runtest)
 (deps
  (alias runtest-test_browser_native_host)
  (alias runtest-test_browser_host_install)))
