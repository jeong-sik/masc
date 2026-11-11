; Absorb-gate counters moved by a finished judgment on each gate path (RFC-0517 §2.2).
(test
 (name test_keeper_librarian_absorb_gate_metrics)
 (modules test_keeper_librarian_absorb_gate_metrics)
 (deps ../config/prompts/librarian.md)
 (libraries alcotest masc masc_test_deps exact_output_fixture eio_main))
