; RFC play-link-for-the-shared-machine §2.6 through the real router: the
; play page is public and self-contained, and the seat names the bearer,
; the DOS controller and whom it can be handed to.

(test
 (name test_play_page)
 (modules test_play_page)
 ; The agent guide renders config/prompts/play.agent_guide.md.
 (deps (source_tree %{workspace_root}/config/prompts))
 (action (run %{test}))
 (libraries masc_test_deps alcotest yojson h2 bigstringaf unix eio eio_main masc.masc_core masc.dos_lane masc.server))

(rule
 (alias runtest-test_play_page_client)
 (deps test_play_page_client.cjs ../lib/server/server_routes_http_routes_play_page.ml)
 (action (run node --test %{dep:test_play_page_client.cjs})))

(alias
 (name runtest)
 (deps (alias runtest-test_play_page_client)))
