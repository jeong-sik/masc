; A wrong-typed leaf in runtime.toml is a load error that names the key
; path, not an Otoml.Type_error escaping Runtime_toml.parse_toml.

(test
 (name test_runtime_toml_wrong_typed_keys)
 (modules test_runtime_toml_wrong_typed_keys)
 (libraries alcotest masc.runtime masc.string_util))
