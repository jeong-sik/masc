; Browser sessions against the writer zone, on real files in temporary
; directories: a session issued at sign-in, the cookies that do not act, a new
; sign-in that ends the session of its browser, a sign-out whose record is not
; appended, the cookie value, and the CSRF token. No network.
;
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_authz_browser_session)
 (modules test_authz_browser_session)
 (libraries masc_test_deps))
