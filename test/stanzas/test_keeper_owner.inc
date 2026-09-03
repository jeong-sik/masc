; The sandbox profile these fixtures declare is incidental: the suite measures
; owner actor/delegate operation semantics, not sandbox isolation.
;
; MASC_EXEC_ALLOW_LOCAL_PLAYGROUND: keeper-up validation rejects a local
; playground fail-closed without the hatch.
;
; MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED=false: since the fixtures declare
; docker, boot runs the Docker preflight, which checks the daemon and the
; masc-keeper-sandbox image. The release evidence job builds neither, so the
; boot failed there for a reason this suite does not measure. The switch skips
; the preflight outright (keeper_sandbox_runtime.docker_preflight returns None),
; leaving the owner semantics under test untouched.
(test
 (name test_keeper_owner)
 (modules test_keeper_owner)
 (action
  (setenv
   MASC_EXEC_ALLOW_LOCAL_PLAYGROUND
   true
   (setenv MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED false (run %{test}))))
 (libraries masc_test_deps))
