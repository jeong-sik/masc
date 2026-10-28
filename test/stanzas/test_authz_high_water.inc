; The judgments of the external high-water mark, on real chains of records and
; states built in memory.

(test
 (name test_authz_high_water)
 (modules test_authz_high_water)
 (action (run %{test}))
 (libraries masc_test_deps masc.agent_core.digest))
