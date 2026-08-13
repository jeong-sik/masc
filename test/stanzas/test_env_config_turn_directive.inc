; Per-file dune stanza for the [Env_config_turn_directive] contract suite.
; Lives here (not in the legacy grouped stanza) per test/stanzas/README.md to
; avoid the conflict-runtime hotspot.

(test
 (name test_env_config_turn_directive)
 (modules test_env_config_turn_directive)
 (libraries masc_test_deps))
