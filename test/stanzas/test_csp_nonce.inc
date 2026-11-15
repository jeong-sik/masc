; The CSP nonce every server page draws (#52098), and the two pages outside the
; account server that carry it: the GraphQL playground and the play page. Pure
; values; no network and no server state.

(test
 (name test_csp_nonce)
 (modules test_csp_nonce)
 (action (run %{test}))
 (libraries masc_test_deps))
