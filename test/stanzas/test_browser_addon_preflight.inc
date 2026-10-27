(test
 (name test_browser_addon_preflight)
 (modules test_browser_addon_preflight)
 (libraries masc masc_test_deps masc.config_dir_resolver masc.browser_lane)
 ; The package that serves external hosts, which the native host check counts.
 (deps
  (source_tree ../addons/browser/external))
 (action
  (setenv MASC_TEST_BROWSER_PACKAGE %{dep:../addons/browser/external/lane.toml}
   (run %{test}))))
