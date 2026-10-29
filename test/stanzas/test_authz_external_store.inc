; The file of the external store, on real files in a temporary directory.

(test
 (name test_authz_external_store)
 (modules test_authz_external_store)
 (action (run %{test}))
 (libraries masc_test_deps masc.agent_core.digest))
