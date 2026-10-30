; Pure checks over ids and scopes; no workspace, no files.

(test
 (name test_authz_scope)
 (modules test_authz_scope)
 (action (run %{test}))
 (libraries masc_test_deps))
