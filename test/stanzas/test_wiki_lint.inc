; Wiki lint rules, link graph, sources section and the log parser: pure
; functions (RFC-wiki-lint-and-page-contracts, step 1b and step 2)

(test
 (name test_wiki_lint)
 (modules test_wiki_lint)
 (libraries masc alcotest unix yojson))
