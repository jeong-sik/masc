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
 (libraries masc_test_deps))
