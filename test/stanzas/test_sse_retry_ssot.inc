; Per-file dune stanza for the SSE retry-interval SSOT suite (RFC-0089).
; Lives here per test/stanzas/README.md to avoid the conflict-runtime hotspot
; in the legacy grouped (tests ...) stanza.

(test
 (name test_sse_retry_ssot)
 (modules test_sse_retry_ssot)
 (libraries masc.server alcotest))
