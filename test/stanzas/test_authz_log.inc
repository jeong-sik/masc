; The file of the authorization log, on real files in a temporary directory. One case starts this executable again as a second process that holds the lock file.

(test
 (name test_authz_log)
 (modules test_authz_log)
 (action (run %{test}))
 (libraries masc_test_deps masc.agent_core.digest))
