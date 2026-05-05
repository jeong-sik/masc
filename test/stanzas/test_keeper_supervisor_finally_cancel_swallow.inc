; 2026-05-05 cycle9 FATAL regression guard.
; Pure source-text inspection; no MASC_BASE_PATH, no project libs.

(test
 (name test_keeper_supervisor_finally_cancel_swallow)
 (modules test_keeper_supervisor_finally_cancel_swallow)
 (deps ../lib/keeper/keeper_supervisor.ml))
