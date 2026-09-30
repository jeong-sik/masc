# Leader-selected CI preparation

Code review and source approval happen first. The MASC leader chooses which
approved PR heads belong in a combined candidate. A PR push, Ready transition
or approval does not start CI.

Source review uses `approve-guard.sh` independently of CI. The preparation
command reads its approval receipts, combines only the leader's explicit
selection, then rechecks approvals and main. This initial path selects open,
Ready ordinary PRs targeting main; stack members become eligible after their base is
integrated and the PR is retargeted to main. Release heads use the explicit
release verification workflow rather than this source-only preparation path.

```sh
python3 scripts/review/prepare-approved-batch.py \
  --repo OWNER/REPO --leader KEEPER --git-dir CHECKOUT \
  --member PR_NUMBER@CURRENT_HEAD_SHA \
  --member ANOTHER_PR_NUMBER@CURRENT_HEAD_SHA \
  --branch ci/LEADER_SELECTION --output SELECTION.json
```

The receipt freezes main, the chosen PR heads and their approval IDs, plus the
combined commit and tree. A newly created local branch retains the candidate.
It changes no checkout and publishes nothing. Conflicts, unapproved members,
head changes, revoked approvals, change requests or a moving main prevent
preparation. No Actions/check-run API reads, build or CI dispatch occur here.

The next step is a separate leader-controlled CI runner for this frozen
candidate. Its result describes the combined candidate. Source approval does
not claim compilation success, CI success or permission to merge.
