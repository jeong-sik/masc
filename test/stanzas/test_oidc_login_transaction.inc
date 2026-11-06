; Logins in flight: a transaction is taken once, with its state, before it
; expires, and the invitation token and the return path parse by grammar.
; No network.

(test
 (name test_oidc_login_transaction)
 (modules test_oidc_login_transaction)
 (action (run %{test}))
 (libraries masc_test_deps))
