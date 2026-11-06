; The google member of the auth configuration: what is read, what is refused,
; and that a rewrite of the file keeps it. No network, no files.
;
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_auth_config_google)
 (modules test_auth_config_google)
 (libraries masc_test_deps))
