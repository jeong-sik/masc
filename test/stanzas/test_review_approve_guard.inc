(test
 (name test_review_approve_guard)
 (modules test_review_approve_guard)
 (deps
  %{workspace_root}/scripts/review/approve-guard.sh
  %{workspace_root}/scripts/review/approve-guard-selftest.sh
  %{workspace_root}/scripts/review/pr-check-run-contract.sh
  %{workspace_root}/.github/workflows/pr-check.yml)
 (libraries alcotest))
