; The allowlist routes against the writer zone on real files: an Admin with a
; browser session registers and removes identities, a Member cannot, and the
; refused requests (no session, no CSRF token, another origin, a body that is
; not an identity, a bound or already registered identity, an unknown id). No
; network.
;
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_login_allowlist_routes)
 (modules test_login_allowlist_routes)
 (libraries masc_test_deps ptime))
