; Per-file dune stanza for the [Coord_bootstrap] regression
; suite.  Lives here per test/stanzas/README.md to avoid the
; conflict-cascade hotspot in the legacy grouped (tests ...)
; stanza.

(test
 (name test_coord_bootstrap)
 (modules test_coord_bootstrap)
 (libraries masc_test_deps str))
