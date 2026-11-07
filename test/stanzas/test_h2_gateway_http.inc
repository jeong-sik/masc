; HTTP/2 requests take the one route table through the shared ingress.

(test
 (name test_h2_gateway_http)
 (modules test_h2_gateway_http)
 (deps fixtures/skill-ledger-async-actions.json)
 (libraries masc_test_deps h2 h2-eio bigstringaf eio.mock))
