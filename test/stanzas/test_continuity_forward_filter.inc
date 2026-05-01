; RFC-MASC-001 Phase 1 prose echo guard: prompt-time summary filter
; strips backward-looking fields (Done, Decisions, Progress) while
; preserving forward-looking ones (Goal, Next plan, Next, etc.).

(test
 (name test_continuity_forward_filter)
 (modules test_continuity_forward_filter)
 (libraries masc_test_deps))
