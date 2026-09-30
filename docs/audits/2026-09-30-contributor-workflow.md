# Contributor workflow source audit

This audit covers six documented paths in
[the workflow](../guides/CONTRIBUTOR-WORKFLOW.md) and its
[Korean translation](../guides/CONTRIBUTOR-WORKFLOW.ko.md).
It checks instructions against versioned source. It is not a new-contributor
usability experiment, installation test, or proof of Keeper continuity.

| Path | Checked implementation/contract | Result |
|---|---|---|
| First contribution | CONTRIBUTING, README source prerequisites, Git worktree/fork branch semantics | Documentation path is available without private MASC access; source build is optional for docs |
| External AI session | AGENTS and constitution execution_protocol | No local Dune build, no CI watch/wait, isolated changes, parallel adversarial review on moving work units |
| Work coordination | config/tools/masc_goal_upsert.toml, masc_add_task.toml, masc_transition.toml, masc_board_post.toml | Goal source/target, explicit Task link, claim/start, handoff and Board purpose documented |
| Validation and CI | .github/workflows/pr-check.yml, test.yml, linux-x64-probe.yml, release.yml | Draft skips required jobs; ready runs five required checks; targeted/full verification and binary probe have distinct purposes |
| Review/integration | constitution, scripts/review/approve-guard.sh, merge-guard.sh, ci-freshness.py | Current head/run, later reviews, base freshness, limited external merge exception and guard required |
| Evidence/resume | config/tools/masc_transition.toml, masc_goal_transition.toml, keeper_task_done.toml | Verification submission, typed evidence, final human Goal confirmation and reread-before-retry documented |

Source-matched procedure count: **6 / 6**. This count measures the coverage of the
written source audit, not independent reviewer acceptance or CI success.

The PR records local document checks, reviewer findings and the current head's
CI separately. MASC tracking: `goal-1790726916307-9cef44ef`, implementation
`task-1849`, independent review `task-1850`, Board
`p-75b0046c83407da9c97fc06ef34fbe7f`. These IDs describe this change; outside
contributors do not need access to those records.

An independent source review checked all six paths. Its findings about optional
Goal links, accepted evidence types and the incorrect RFC evidence link were
addressed; its reviewer-request cleanup guidance was added. This is a document
review, not the completion authority’s verdict.

Remaining verification: Task review acceptance, current-head PR checks,
and eventual operator confirmation of the Goal. A plan posted on the Board and
this audit do not complete either Task automatically.
