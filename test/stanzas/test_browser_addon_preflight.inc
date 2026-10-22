(test
 (name test_browser_addon_preflight)
 (modules test_browser_addon_preflight)
 (libraries masc masc_test_deps masc.config_dir_resolver)
 (deps
  (source_tree ../addons/browser))
 (action
  (setenv MASC_TEST_BROWSER_PACKAGE %{dep:../addons/browser/lane.toml}
   (run %{test}))))
