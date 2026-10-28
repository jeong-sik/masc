; The file machinery under the authorization log, with line formats of its own, on real files in a temporary directory.

(test
 (name test_authz_jsonl_file)
 (modules test_authz_jsonl_file)
 (action (run %{test}))
 (libraries masc_test_deps masc.agent_core.digest))
