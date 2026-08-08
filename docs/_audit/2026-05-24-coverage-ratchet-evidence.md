# Coverage ratchet evidence - 2026-05-24

Scope: #1175 Stage A/B correction. Current CI coverage has recovered above the
stale 22% floor, so the workflow threshold should ratchet upward instead of
waiting for another coverage-specific test PR.

## Measurement

- Evidence: GitHub Actions full CI coverage report on PR #1707.
- Run: `26352648077`
- Job: `77573496681`
- Command checked: `gh run view 26352648077 --job 77573496681 --log`
- Measured coverage: `70.90%` (`21176/29866`)
- Timestamp: 2026-05-24 KST
- Confidence: High

## Ratchet decision

- Previous threshold: `22`
- New threshold: `69`
- Formula: `floor(70.90 - 1) = 69`
- Reason: preserve one percentage point of CI/runtime headroom while making the
  recovered coverage floor enforceable.

## #1175 record

- Stage A target (`22 -> 40`): satisfied by this measurement.
- Stage B target (`40 -> 60`): satisfied by this measurement.
- Next target: Stage C (`60 -> 75`), then Stage D (`75 -> 80`).
- Top 0% files removed in this PR: none.
- Tests added in this PR: none; this is a ratchet correction based on an
  already-successful full CI measurement.
