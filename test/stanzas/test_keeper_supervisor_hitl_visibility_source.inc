; HITL approval visibility source guard.
; Pure source-text inspection; no MASC_BASE_PATH, no project libs.

(test
 (name test_keeper_supervisor_hitl_visibility_source)
 (modules test_keeper_supervisor_hitl_visibility_source)
 (libraries str)
 (deps ../lib/keeper/keeper_supervisor.ml))
