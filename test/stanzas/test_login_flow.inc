; Google and GitHub logins from the start to the admission, with both providers
; played by the test: Google reads the nonce and the S256 challenge of the
; authorization URL, signs the ID token with an RSA key made for the run, and
; checks the verifier; GitHub checks the verifier and the client and answers
; GET /user for the token it issued. The installation is bootstrapped in a
; temporary directory. No network.
;
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_login_flow)
 (modules test_login_flow)
 (libraries masc_test_deps jose mirage-crypto-pk digestif ptime))
