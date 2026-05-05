; Per-file dune stanza for the [Briefing_compactors] regression
; suite.  Lives here per test/stanzas/README.md to avoid the
; conflict-cascade hotspot in the legacy grouped (tests ...)
; stanza.

(test
 (name test_briefing_compactors)
 (modules test_briefing_compactors)
 (libraries masc_test_deps))
