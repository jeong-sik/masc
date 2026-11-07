; The cookies of a browser login and the check of a request that carries the
; session cookie, against the writer zone on real files: a request that acts
; through its session, the refusals (a query credential, a bearer beside the
; cookie, another origin, a missing origin or CSRF token, a session that does
; not act), and the Set-Cookie values. No network.
;
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_authz_browser_request)
 (modules test_authz_browser_request)
 (libraries masc_test_deps))
