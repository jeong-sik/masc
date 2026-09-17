; How one provider request's digests differ from the previous request of the
; same keeper turn: every message change shape, the system prompt and tool
; flags, and long repeated histories.

(test
 (name test_keeper_projection_change)
 (modules test_keeper_projection_change)
 (libraries alcotest masc masc_test_deps))
