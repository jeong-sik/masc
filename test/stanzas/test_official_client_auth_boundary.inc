; HIGH-RISK-UNREVIEWED: auth-boundary canary for official-client hosts (#39314).
; The read hook must sit beside the test executable, where
; Runtime_antigravity_home.prepare_read_hook looks for it.
(test
 (name test_official_client_auth_boundary)
 (modules test_official_client_auth_boundary)
 (deps masc-antigravity-path-hook)
 (libraries masc_test_deps))
