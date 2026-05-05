; 2026-05-05 fleet-stuck regression guard.
; Pure source-text inspection — no MASC_BASE_PATH, no project libs.
; Declares the inspected source as a dep so dune tracks it.

(test
 (name test_keeper_turn_slot_release_cancel_safe)
 (modules test_keeper_turn_slot_release_cancel_safe)
 (deps ../lib/keeper/keeper_turn_slot.ml))
