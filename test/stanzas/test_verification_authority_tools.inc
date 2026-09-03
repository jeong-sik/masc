; RFC-0361 D1. The completion authority's lookup surface is confined to the
; producer under review, and every call resolves to a result or a stated error.

(test
 (name test_verification_authority_tools)
 (modules test_verification_authority_tools)
 (action
  (setenv
   MASC_EXEC_ALLOW_LOCAL_PLAYGROUND
   true
   (run %{test})))
 (libraries
  masc_test_deps
  ;; The producer runs on the remote_ssh profile: the fixture endpoint row is
  ;; rendered by the same encoder the strict decoder mirrors, and the fake
  ;; shim's result trailer by the same function the real shim uses, so a wire
  ;; change updates these fixtures or fails to compile.
  exec_ssh_protocol))
