; Per-file dune stanza for the nickname word-list SSOT suite.
; Lives here per test/stanzas/README.md to avoid the conflict-runtime hotspot
; in the legacy grouped (tests ...) stanza.

(test
 (name test_nickname_words_ssot)
 (modules test_nickname_words_ssot)
 (libraries masc.config masc.masc_workspace masc.auth alcotest))
