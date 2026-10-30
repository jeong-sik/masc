; Pure checks over the body of an authorization log record; no workspace, no files.

(test
 (name test_authz_body)
 (modules test_authz_body)
 (action (run %{test}))
 (libraries masc_test_deps))
