; The host side of Service credentials (plan C4-9), on real files in temporary
; directories: an issued token acts as its service until it is revoked, the
; list shows each credential with no secret, and a refused call writes nothing.
;
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_authz_service_credential_host)
 (modules test_authz_service_credential_host)
 (libraries masc_test_deps))
