; The fresh bootstrap, on real files in temporary directories: a first run, the
; refusals that leave every file as it was, and the runs after a first run that
; stopped.
;
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_authz_bootstrap)
 (modules test_authz_bootstrap)
 (libraries masc_test_deps masc.agent_core.digest))
