; Logins in flight: a sealed transaction opens with its state before it
; expires, under the key that sealed it, and the invitation token and the
; return path parse by grammar. No network.

(test
 (name test_oidc_login_transaction)
 (modules test_oidc_login_transaction)
 (action (run %{test}))
 (libraries base64 masc_test_deps))
