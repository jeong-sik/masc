; Pure classification over fixture credentials; no workspace, no files.

(test
 (name test_auth_token_inventory)
 (modules test_auth_token_inventory)
 (action (run %{test}))
 (libraries masc_test_deps))
