; OAS Worker (suppresses warning 32)
; setenv isolates MASC_BASE_PATH so tests never touch the developer's
; live ~/.masc config when run via `dune test`.

(test
 (name test_oas_worker)
 (modules test_oas_worker)
 (ocamlopt_flags (:standard -w -32))
 (action
  (setenv MASC_BASE_PATH /tmp/test-oas-worker
   (setenv MASC_BASE_PATH_INPUT /tmp/test-oas-worker
    (run %{test}))))
 (libraries masc_test_deps))
