; The play invite routes, driven through the real router: who may issue an
; invite, what the answer carries, and that revoking frees the DOS controller.

(test
 (name test_play_invite_routes)
 (modules test_play_invite_routes)
 (action (run %{test}))
 (libraries machine_worker_fixture masc.machine_configuration masc_test_deps alcotest yojson bigstringaf unix eio eio_main masc.dos_lane masc.server))
