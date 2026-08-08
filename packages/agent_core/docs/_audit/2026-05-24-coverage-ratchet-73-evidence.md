# Coverage ratchet evidence - 2026-05-24 - threshold 73

Scope: #1175 Stage C incremental ratchet after the runtime replay checkpoint
delta slice improved measured coverage above the current 72% floor.

## Measurement

- Evidence: GitHub Actions full CI coverage report on PR #1738.
- Run: `26360879180`
- Job: `77595953724`
- Command checked: `gh run view 26360879180 --job 77595953724 --log`
- Measured coverage: `74.47%` (`22353/30018`)
- Timestamp: 2026-05-24 KST
- Confidence: High

## Ratchet decision

- Previous threshold: `72`
- New threshold: `73`
- Formula: `floor(74.47 - 1) = 73`
- Reason: preserve one percentage point of CI/runtime headroom while making the
  post-#1738 recovered coverage floor enforceable.

## #1175 record

- Stage C target (`60 -> 75`): still in progress; measured coverage is now
  `74.47%`, just below the 75% stage line.
- Top 0% files removed in this PR: none.
- Tests added in this PR: none; this is a ratchet correction based on an
  already-successful full CI measurement from #1738.
- Next target: one focused coverage slice to reach measured coverage >= 76%,
  then ratchet to at least `75`.
