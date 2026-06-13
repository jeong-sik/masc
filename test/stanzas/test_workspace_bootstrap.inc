; Per-file dune stanza for the [Workspace_bootstrap] regression
; suite.  Lives here per test/stanzas/README.md to avoid the
; conflict-runtime hotspot in the legacy grouped (tests ...)
; stanza.

(test
 (name test_workspace_bootstrap)
 (modules test_workspace_bootstrap)
 (libraries masc_test_deps str))
