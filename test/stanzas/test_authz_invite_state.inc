; The invitations that the invite records add up to: who may write which event,
; that an id and a token digest name one invitation for good, and revocation.
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_authz_invite_state)
 (modules test_authz_invite_state)
 (libraries masc_test_deps))
