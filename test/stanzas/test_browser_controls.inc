(test
 (name test_browser_controls)
 (modules test_browser_controls)
 (libraries browser_addon_fixture masc_test_deps masc masc.browser_lane masc.time_compat masc.tool_types alcotest eio eio_main)
 (deps ../bin/masc_native_addon_launcher.exe))
