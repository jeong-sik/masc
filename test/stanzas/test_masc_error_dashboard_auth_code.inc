; Per-file dune stanza for the
; [Masc_error.dashboard_auth_error_code] SSOT mapping suite. Lives here
; per test/stanzas/README.md to avoid the conflict-runtime hotspot in the
; legacy grouped (tests ...) stanza.

(test
 (name test_masc_error_dashboard_auth_code)
 (modules test_masc_error_dashboard_auth_code)
 (libraries masc_test_deps))
