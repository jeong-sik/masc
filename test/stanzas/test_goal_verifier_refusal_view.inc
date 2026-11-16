; RFC-0489 §2.2/§2.6 — the Goal-side view reads a run-ended refusal and an
; owner-less dispatch as themselves, and keeps every other object on its
; existing reviewer-refusal path.

(test
 (name test_goal_verifier_refusal_view)
 (modules test_goal_verifier_refusal_view)
 (libraries masc_test_deps))
