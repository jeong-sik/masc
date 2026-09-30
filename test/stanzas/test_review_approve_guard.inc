(test
 (name test_review_approve_guard)
 (modules test_review_approve_guard)
 (deps
  %{workspace_root}/scripts/review/approve-guard.sh
  %{workspace_root}/scripts/review/merge-guard.sh
  %{workspace_root}/scripts/review/ci-checks.sh
  %{workspace_root}/scripts/review/review-verdict.sh
  %{workspace_root}/scripts/review/queue-ledger.sh
  %{workspace_root}/scripts/review/test_source_review_policy.py)
 (libraries alcotest))
