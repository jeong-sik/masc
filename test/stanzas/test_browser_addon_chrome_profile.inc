(test
 (name test_browser_addon_chrome_profile)
 (modules test_browser_addon_chrome_profile)
 (libraries masc_test_deps masc.browser_lane masc.browser_configuration
  masc.native_addon_lease masc_process eio.unix yojson)
 (deps ../bin/masc_native_addon_launcher.exe ../bin/masc_browser_process_owner.exe)
 (action (run %{test} %{dep:../bin/masc_native_addon_launcher.exe} %{dep:../bin/masc_browser_process_owner.exe})))
