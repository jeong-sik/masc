; masc config set: the writer of runtime.toml keys the settings registry names.
; A key or value the registry does not accept never reaches the file, and what is
; written is what the loader applies.
(test
 (name test_runtime_setting_set)
 (modules test_runtime_setting_set)
 (libraries masc_test_deps masc.runtime_setting_set))
