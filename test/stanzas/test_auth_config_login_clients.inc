; The google and github members of the auth configuration: what is read, what
; is refused, and that a rewrite of the file keeps them. No network, no files.
;
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_auth_config_login_clients)
 (modules test_auth_config_login_clients)
 (libraries masc_test_deps))
