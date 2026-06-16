; Per-file dune stanza for the P0-1 registry visible-tag coverage boot-safety
; suite. Lives here per test/stanzas/README.md to avoid the conflict-runtime
; hotspot in the legacy grouped (tests ...) stanza.

(test
 (name test_registry_visible_tag_coverage)
 (modules test_registry_visible_tag_coverage)
 (libraries masc alcotest))
