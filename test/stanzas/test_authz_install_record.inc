; The install record, on real files in a temporary directory.

(test
 (name test_authz_install_record)
 (modules test_authz_install_record)
 (action (run %{test}))
 (libraries masc_test_deps masc.agent_core.digest))
