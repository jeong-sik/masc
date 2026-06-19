; Per-file dune stanza for the legacy protocol-alias rejection suite.
; Lives here per test/stanzas/README.md to avoid the conflict-runtime hotspot
; in the legacy grouped (tests ...) stanza.

(test
 (name test_legacy_protocol_alias_rejected)
 (modules test_legacy_protocol_alias_rejected)
 (libraries masc.runtime alcotest))
