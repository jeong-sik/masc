; Per-file dune stanza for the typed keeper surface_status suite (RFC-0089).
; Lives here per test/stanzas/README.md to avoid the conflict-runtime hotspot
; in the legacy grouped (tests ...) stanza.

(test
 (name test_keeper_surface_status)
 (modules test_keeper_surface_status)
 (libraries masc_test_deps masc alcotest))
