; Per-file dune stanza for the [Keeper_alerting_path] root /
; allowed-norms boundary regression suite.  Lives here per
; test/stanzas/README.md to avoid the conflict-cascade hotspot
; in the legacy grouped (tests ...) stanza.

(test
 (name test_keeper_alerting_path_norms)
 (modules test_keeper_alerting_path_norms)
 (libraries masc_test_deps))
