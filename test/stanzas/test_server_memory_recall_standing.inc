; The memory recall gate per declared Keeper, as the server reads it, and the
; JSON of GET /api/v1/runtime/config/memory-recall.
;
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_server_memory_recall_standing)
 (modules test_server_memory_recall_standing)
 (libraries masc alcotest masc_test_deps))
