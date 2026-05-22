; Shell IR Adjacent Surfaces Plan P9a — contract tests for the
; Keeper_gh_shared gh-command parser surface. Locks behavior before
; P9b decides typed gh_args vs dedicated GitHub op split.

(test
 (name test_keeper_gh_parser_contract)
 (modules test_keeper_gh_parser_contract)
 (libraries masc_test_deps alcotest))
