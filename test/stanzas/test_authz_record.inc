; Pure checks over one record of the authorization log; no workspace, no files.

(test
 (name test_authz_record)
 (modules test_authz_record)
 (action (run %{test}))
 (libraries masc_test_deps))
