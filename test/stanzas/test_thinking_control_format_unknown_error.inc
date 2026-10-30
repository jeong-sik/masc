; Per-file dune stanza for the thinking-control-format unknown->Error suite
; (RFC-0089). Lives here per test/stanzas/README.md to avoid the
; conflict-runtime hotspot in the legacy grouped (tests ...) stanza.

(test
 (name test_thinking_control_format_unknown_error)
 (modules test_thinking_control_format_unknown_error)
 (libraries masc.runtime alcotest))
