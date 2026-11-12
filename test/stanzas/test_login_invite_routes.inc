; The invitation routes against the writer zone on real files: an Admin with a
; browser session issues invitations of either role and revokes one, the
; holder of a link joins with its role, a Member does neither, and the
; refused requests (no session, no CSRF token, another origin, a body that
; names no role, an unknown id). No network.
;
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_login_invite_routes)
 (modules test_login_invite_routes)
 (libraries masc_test_deps ptime))
