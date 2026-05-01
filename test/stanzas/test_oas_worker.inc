; OAS Worker (suppresses warning 32)

(test
 (name test_oas_worker)
 (modules test_oas_worker)
 (ocamlopt_flags (:standard -w -32))
 (libraries masc_test_deps))
