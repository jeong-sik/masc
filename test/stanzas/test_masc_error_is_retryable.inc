; Per-file dune stanza for the [Masc_error.is_retryable]
; classification suite. Lives here per test/stanzas/README.md to
; avoid the conflict-cascade hotspot in the legacy grouped
; (tests ...) stanza.

(test
 (name test_masc_error_is_retryable)
 (modules test_masc_error_is_retryable)
 (libraries masc_test_deps))
