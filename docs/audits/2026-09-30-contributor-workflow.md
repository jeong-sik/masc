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
| Validation and CI | constitution, .github/workflows/pr-check.yml, ci.yml, release-candidate.yml, test.yml | Ready enables review, not automatic CI; explicit minimal jobs are limited to two minutes, Core belongs at the stack bottom, and full verification belongs at Release/Tag |
| Review/integration | constitution, scripts/review/approve-guard.sh, merge-guard.sh, ci-checks.sh | Ordinary current-head source PASS has no run ID; independent approval and resolved P0/P1/P2 govern admission; Release requires successful full current-head CI |
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

Remaining verification: Task review acceptance and eventual operator confirmation
of the Goal. Ordinary source review does not require a CI run; Release/Tag
verification remains separate. A plan posted on the Board and
this audit do not complete either Task automatically.


## Historical onboarding reviews and external comparison

The following records describe earlier revisions. Their automatic CI and
run-freshness requirements are historical, not current contributor procedures.
The current policy reconciliation below supersedes that guidance.

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


## Second factual review after presentation changes

The earlier layout and link checks were insufficient to certify executable
procedures. A second source read found the following defects and ambiguities:

| Finding | Source | Correction |
|---|---|---|
| Human setup ran an Alcotest suite without installing test dependencies | `masc.opam` / `masc.opam.locked`: Alcotest and QCheck have `with-test` filters | Added `--with-test` to contributor dependency installation |
| Fresh opam installation was not initialized | README's source setup includes `opam init --bare` | Added the missing initialization step |
| Release guard was described as unwired | `scripts/ci/run-lint-suite.sh` invokes it in blocking-pr mode | Corrected the release section |
| Unqualified Task release advice fails after verification submission | `workspace_task_lifecycle.ml`: release rejects AwaitingVerification | Documented claim/start, eligible release states, pending verification handoff and reasoned cancellation |
| A code commit can violate the external session's no-build rule through a configured hook | `.githooks/pre-commit` invokes `dune build --root .` for code | Documented a commit-only hook override, preserving the normal pre-push guard and CI requirement |
| Green TLA job was liable to be mistaken for an executed model check | `pr-check.yml` executes TLC only for changed `specs/` | Documented step-level evidence requirement |
| Human launch example used the shared-runtime script and implicit port | `scripts/run-local.sh` explicitly provides a separate target/config root | Used the local launcher with a separate directory and an example port that must be unused |
| Generic doc-truth success could be mistaken for review of the new guide | `scripts/check-doc-truth.sh` has a bounded document list and assertions | Stated the check's scope and separate link/command review |

English/Korean guide changes were checked together. An independent reviewer
identified the release-state, hook and opam-initialization findings in a source
read. Source review still does not establish fresh-machine install success or
actual runtime behavior. Main was integrated after the GitHub reviewer reported
that the earlier green PR run failed freshness; the revised head needs new CI.

The fix review identified inherited `MASC_CONFIG_DIR` as an escape from the
launch example's separate config root. The example now clears that variable for
the command and states that existing target-directory configuration still applies.


## Current policy reconciliation

At `836ba279c2b30fdae1a2163e04e6e306ba88e898`, the English and Korean guides and
CONTRIBUTING follow the full constitution's execution protocol: stacked work,
ordinary independent source review, no automatic PR/push/scheduled CI,
explicitly requested minimal jobs limited to two minutes, Core at the bottom
of a stack, and the full cycle at Release/Tag. Ready-for-review changes review
readiness, not CI triggers.

Ordinary verdicts bind the current head without a run ID. Release verdicts
also cite the completed successful full run. Approval and merge guards retain
exact-head identity, independent approval and later blocking reviews. Parents
land first; a changed child base/diff is reviewed before integration. Human/fork
onboarding, Keeper toolchain permission, typed evidence and runtime isolation
remain in both guides. The removed documentation checker is not an active
command, and no deleted review module is restored by this reconciliation.

The audit table above describes that current policy. Earlier audit notes remain
historical records of the source and findings at their review time. None of
those records supplies a current-head CI verdict, Task acceptance, fresh-machine
installation proof or runtime observation. The original tracking IDs above
remain historical records, not new acceptance.
