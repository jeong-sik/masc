; One round of a Keeper's Memory writer on the wiring a server gives it:
; runtime table, lane value, closed turn, ask, commit and the health row
; (RFC librarian-call-only-proposes §20). The ask renders the shipped prompt.
(test
 (name test_librarian_cycle_one_round)
 (modules test_librarian_cycle_one_round)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries masc_test_deps exact_output_fixture))
