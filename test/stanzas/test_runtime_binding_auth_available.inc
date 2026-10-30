; Per-file dune stanza for the runtime binding auth-availability suite.

(test
 (name test_runtime_binding_auth_available)
 (modules test_runtime_binding_auth_available)
 (libraries alcotest masc_test_deps))
