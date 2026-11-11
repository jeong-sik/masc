; The PAT routes against the writer zone on real files: a person with a
; browser session issues, lists and revokes their own PATs, sees nothing of
; another person's, and the refused requests (no session, no CSRF token,
; another origin, a body with no scope or a past expiry, a bad id). No
; network.
;
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_login_pat_routes)
 (modules test_login_pat_routes)
 (libraries masc_test_deps ptime))
