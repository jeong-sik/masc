; TOML-only config guard: production keeper_meta_json_parse must ignore config
; keys in persisted JSON (keeper.json = runtime state; keeper.toml = config SSOT).
; The test helper re-injects config for fixture convenience (test-only path).

(test
 (name test_keeper_meta_json_config_toml_only)
 (modules test_keeper_meta_json_config_toml_only)
 (libraries masc_test_deps))
