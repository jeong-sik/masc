# PR #2706 CI Blocker: governance pipeline baseline failures

- Date: 2026-03-24
- Related PR: #2706
- Tracking issue: #2707

## Symptom

- GitHub Actions `Build and Test` failed for PR #2706 in run `23445658152`, job `68208539273`.
- The failing suite is `test/test_governance_pipeline.exe`, not the keeper bridge patch itself.

## Reproduction

- `dune exec --root /Users/dancer/me/workspace/yousleepwhen/masc-mcp test/test_governance_pipeline.exe`

## Observed Result

- `risk_assessment` case `medium: claim` expects `medium` but currently returns `low`.
- `pre_hook_integration` case `blocked response structure` also fails in the same suite.
- `test/test_operator_control.exe` passes locally on PR #2706, so the keeper bridge fix is not the CI regression source.

## Suspected Cause

- Governance risk classification or blocked-response shape changed on `main` without keeping `test/test_governance_pipeline.ml` in sync.

## Tried

1. Queried the failing GitHub Actions job log for PR #2706.
2. Isolated the failure markers to `risk_assessment` and `pre_hook_integration`.
3. Reproduced the same failures locally on current `main`.
4. Confirmed the keeper bridge patch passes `test/test_operator_control.exe` and `test/test_tool_keeper.exe`.

## Next Steps

1. Inspect `test/test_governance_pipeline.ml` around the `medium: claim` and `blocked response structure` cases.
2. Compare current governance risk classification logic and blocked-response JSON shape against those expectations.
3. Fix #2707 separately, then re-run PR #2706 checks.

## Gotchas

- This blocker is independent of the `masc_keeper_msg` auto team-session bridge fix in PR #2706.
- `Build and Test` will remain red for PR #2706 until #2707 is addressed or the baseline is repaired.
