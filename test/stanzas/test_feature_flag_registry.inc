; Per-file dune stanza for the [Feature_flag_registry] pure-helper
; regression suite.  Lives here per test/stanzas/README.md to
; avoid the conflict-cascade hotspot in the legacy grouped
; (tests ...) stanza.

(test
 (name test_feature_flag_registry)
 (modules test_feature_flag_registry)
 (libraries masc_test_deps))
