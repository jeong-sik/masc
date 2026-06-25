; keeper-v2 #9 response-feedback Phase 1a: pure typed model + codec + tally.
; Per-file stanza per test/stanzas/README.md (avoids the grouped-stanza
; conflict hotspot).

(test
 (name test_keeper_response_feedback)
 (modules test_keeper_response_feedback)
 (libraries masc_test_deps))
