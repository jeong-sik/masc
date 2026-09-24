(test
 (name test_review_approve_guard)
 (modules test_review_approve_guard)
 (deps
  %{workspace_root}/scripts/review/approve-guard.sh
  %{workspace_root}/scripts/review/approve-guard-selftest.sh)
 (libraries alcotest))
