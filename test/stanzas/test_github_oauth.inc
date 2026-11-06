; The exchange of a GitHub login, with GitHub played by the test: the token
; endpoint checks the form and the headers GitHub asks for, and the user
; endpoint checks the bearer token, the API version and the User-Agent. No
; network.
;
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_github_oauth)
 (modules test_github_oauth)
 (libraries masc_test_deps))
