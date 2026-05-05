; Per-file dune stanza for the [Dashboard_feature_health]
; pure-helper regression suite.  Lives here per
; test/stanzas/README.md to avoid the conflict-cascade hotspot
; in the legacy grouped (tests ...) stanza.

(test
 (name test_dashboard_feature_health)
 (modules test_dashboard_feature_health)
 (libraries masc_test_deps))
