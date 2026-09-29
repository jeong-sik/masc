; tools/list records a tool assignment under the verified credential's owner,
; never the bearer.

(test
 (name test_tools_list_assignment_agent)
 (modules test_tools_list_assignment_agent)
 (action (run %{test}))
 (libraries masc_test_deps alcotest yojson unix eio eio_main mirage-crypto-rng.unix masc.masc_core))
