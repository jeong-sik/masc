; Per-file dune stanza for the [Env_config_core.get_ratio]
; regression suite.  Lives here (not in the legacy grouped
; stanza) per test/stanzas/README.md to avoid the
; conflict-cascade hotspot.

(test
 (name test_env_config_get_ratio)
 (modules test_env_config_get_ratio)
 (libraries masc_test_deps))
