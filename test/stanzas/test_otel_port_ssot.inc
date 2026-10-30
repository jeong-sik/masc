; Per-file dune stanza for the OTLP port SSOT suite (RFC-0089).
; Lives here per test/stanzas/README.md to avoid the conflict-runtime hotspot
; in the legacy grouped (tests ...) stanza.

(test
 (name test_otel_port_ssot)
 (modules test_otel_port_ssot)
 (libraries masc.otel_spans masc.config uri alcotest))
