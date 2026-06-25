; Per-file dune stanza for the typed eio-context error classification
; suite. Lives here per test/stanzas/README.md to avoid the
; conflict-runtime hotspot in the legacy grouped (tests ...) stanza.

(test
 (name test_runtime_oas_eio_context_classify)
 (modules test_runtime_oas_eio_context_classify)
 (libraries masc_test_deps))
