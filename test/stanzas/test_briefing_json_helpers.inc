; Per-file dune stanza for the [Briefing_json_helpers]
; pure-helper regression suite.  Lives here per
; test/stanzas/README.md to avoid the conflict-cascade hotspot
; in the legacy grouped (tests ...) stanza.

(test
 (name test_briefing_json_helpers)
 (modules test_briefing_json_helpers)
 (libraries masc_test_deps))
