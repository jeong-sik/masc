; Dashboard reader for the per-turn raw-trace store. That store holds both
; autonomous and direct turns (keeper_turn.ml runs direct masc_keeper_msg
; turns through the same Keeper_agent_run.run_turn), and only the autonomous
; ones belong in the dashboard transcript — a direct turn is already
; persisted in the keeper chat store, so emitting it here would double it.
; The reader also sits on the chat read path, so a corrupt turn file must
; degrade to a skip rather than fail the request.

(test
 (name test_keeper_autonomous_turn_source)
 (modules test_keeper_autonomous_turn_source)
 (libraries masc_test_deps))
