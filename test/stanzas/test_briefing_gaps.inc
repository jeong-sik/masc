; Per-file dune stanza for the [Briefing_gaps] regression suite.
; Lives here per test/stanzas/README.md to avoid the
; conflict-cascade hotspot in the legacy grouped (tests ...)
; stanza.

(test
 (name test_briefing_gaps)
 (modules test_briefing_gaps)
 (libraries masc_test_deps))
