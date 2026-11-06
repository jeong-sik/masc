; The claim check of Google ID tokens: issuer, audience, nonce, and subject
; of payloads written in the test. No network, no clock, no keys.

(test
 (name test_oidc_google)
 (modules test_oidc_google)
 (action (run %{test}))
 (libraries masc_test_deps))
