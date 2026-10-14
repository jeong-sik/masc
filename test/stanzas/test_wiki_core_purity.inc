; The wiki lint's modules reach no file, clock, thread or tool: the source is
; the evidence (RFC-wiki-lint-and-page-contracts §11.1 item 5)

(test
 (name test_wiki_core_purity)
 (modules test_wiki_core_purity)
 (deps
  ../lib/wiki_page_name.ml
  ../lib/wiki_page_name.mli
  ../lib/wiki_page.ml
  ../lib/wiki_page.mli
  ../lib/wiki_link.ml
  ../lib/wiki_link.mli
  ../lib/wiki_sources.ml
  ../lib/wiki_sources.mli
  ../lib/wiki_log.ml
  ../lib/wiki_log.mli
  ../lib/wiki_graph.ml
  ../lib/wiki_graph.mli
  ../lib/wiki_lint.ml
  ../lib/wiki_lint.mli
  ../lib/wiki_lint_report.ml
  ../lib/wiki_lint_report.mli)
 (libraries alcotest))
