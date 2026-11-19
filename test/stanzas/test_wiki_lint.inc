; Wiki lint rules, link graph, sources section and the log parser: pure
; functions

(test
 (name test_wiki_lint)
 (modules test_wiki_lint)
 (libraries masc alcotest unix yojson))
