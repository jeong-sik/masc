; Per-file dune stanza for the [Env_config_core.get_int_nonneg] /
; [Env_config_core.get_float_nonneg] regression suite.  Lives
; here (not in the legacy grouped stanza) per
; test/stanzas/README.md to avoid the conflict-cascade hotspot.

(test
 (name test_env_config_nonneg)
 (modules test_env_config_nonneg)
 (libraries masc_test_deps))
