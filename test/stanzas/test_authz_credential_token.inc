; The text of a PAT and of a Service credential: what a drawn token writes, how
; it reads back, the digest of its secret, and the texts that are not a token.
; No files, clock, or network. There is no (action ...) field, so the targeted
; CI runner builds the executable before the suite starts and only the run is
; under the timeout.

(test
 (name test_authz_credential_token)
 (modules test_authz_credential_token)
 (libraries masc_test_deps masc.agent_core.digest))
