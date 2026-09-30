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

After these workflow changes are integrated into main, publish the prepared
candidate branch explicitly and dispatch `leader-ci.yml` on main. Set its
`candidate` input to the receipt's exact candidate SHA.
Supply the preparation receipt as the `selection` JSON input. Select any of
`compile` (bottom Core only) or `tests`; both default to false. `tests` requires
explicit nonempty `suites` and uses the minimal runner. Every ordinary job,
including setup, is limited to two minutes. Broad release-profile, dashboard,
TLA, lint and full behavior checks remain in `release-candidate.yml` on a
release branch or version tag. There is no changed-file heuristic choosing
work for the leader.

The runner rechecks current source approvals using the integrated main guard,
reconstructs the combined Git commit, and requires it to equal the explicit candidate
SHA. Moved main/heads, revoked approvals and a different candidate prevent
build jobs from starting. The trusted workflow definition comes from main; every selected job checks
out the exact candidate SHA;
checks not selected remain skipped and are not counted as passing. The result
artifact records the candidate, actor, input selection, scopes and results.
The `leader` receipt field records the caller's stated Keeper identity; GitHub
repository permissions authorize dispatch. This CLI does not authenticate a
Keeper runtime leadership role.

Repository CI workflows have no PR/push/tag/scheduled triggers. Specialized
proof and packaging workflows retain manual dispatch. Release publication is
an explicit `publish=true` dispatch on an existing v* tag. Issue taxonomy is
operational issue automation and remains independent of CI. Disabled GitHub
workflow states remain disabled until these definitions are integrated;
reenabling an old automatic definition would violate this policy.

The result describes the combined candidate and the selected coverage. It is
not an individual member's check and does not authorize merge. Ordinary
review guards require current independent source approval; Release admission
requires its own current-head full verification. A combined result cannot
replace either authority. Source approval remains independent of compilation
and test results. No daily schedule is introduced.
