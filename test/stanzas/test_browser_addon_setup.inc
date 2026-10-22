(test
 (name test_browser_addon_setup)
 (modules test_browser_addon_setup)
 (libraries masc_test_deps masc.embedded_browser_addon)
 ; The source package, to compare with the files the binary carries.
 (deps
  (source_tree ../addons/browser)))
