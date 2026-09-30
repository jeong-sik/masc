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


## Adversarial self-review and external comparison

Reviewed on 2026-09-30. This review asks whether a contributor without repository
write access or a private MASC session can follow the document. Findings below
were addressed in both language guides; they remain self-review evidence.

| Finding | Consequence | Revision |
|---|---|---|
| Fork instructions assumed an existing upstream remote | A new fork user could not follow the worktree commands as written | Added fork creation prerequisite, clone, upstream remote, fetch and push destination |
| Search covered only open PRs | A merged fix or rejected approach could be proposed again | Added all-state issue/PR search and current-source search |
| Procedures did not help choose a contribution or source area | A newcomer had to understand internal workflow before finding a small change | Added contribution routes, a source map and a first documentation patch path |
| AI output responsibility was implicit | Generated claims or self-review could be mistaken for verification | Added author ownership and explicit checked/unverified evidence boundaries |
| Review updates could become scattered comments | Reviewers had to reconstruct current scope and evidence | Added PR-body updates when scope, evidence or risks change |

Primary comparison sources read on the review date:

- [OpenClaw CONTRIBUTING](https://github.com/openclaw/openclaw/blob/main/CONTRIBUTING.md):
  contribution routing, plain-language problem/impact, author responsibility and
  keeping the PR body current informed the entrypoint and review guidance.
- [Hermes CONTRIBUTING](https://github.com/NousResearch/hermes-agent/blob/main/CONTRIBUTING.md):
  searching existing issues, all PR states and current source informed the search
  step. Its capability placement discussion highlighted the need to state where
  a change belongs; MASC's map follows its own current source layout.
- [Hermes AGENTS](https://github.com/NousResearch/hermes-agent/blob/main/AGENTS.md):
  area-specific reading routes informed the source map. MASC keeps its root
  AGENTS thin and does not claim Hermes's scoped files or plugin architecture.

These links track upstream main and may change. This comparison adopts navigation
and evidence practices; MASC's constitution remains the policy authority. No
external PR caps, plugin-only placement rules or testing policy were introduced.
The fork commands were reviewed against Git semantics, not exercised with a real
new contributor account. Local document checks and PR CI are recorded in the PR.

A follow-up independent source review found no blocking issues in these revisions.
Its translation clarification was applied. This does not provide a GitHub
approval or a current-head CI verdict.
