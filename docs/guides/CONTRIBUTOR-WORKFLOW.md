# Repository strategy and contributor workflow

[한국어](CONTRIBUTOR-WORKFLOW.ko.md) · [Contributing](../../CONTRIBUTING.md)

This guide describes how a change moves from a problem to a reviewed result in
MASC. It applies to people, external coding agents and Keeper development lanes.
The [constitution](../constitution.xml), especially `execution_protocol`, owns
the repository's development contract. This guide explains how to apply it;
workflow YAML and scripts show what is currently enforced.

## Repository strategy

- `main` is the integration branch. Start independent changes from current main.
- Give one PR one concrete outcome. Split genuinely dependent work into stacked
  PRs; start independent changes in separate branches from main.
- Keep concurrent changes in separate worktrees. Task claims coordinate who is
  doing the work; they do not lock files or authorize editing another checkout.
- Document the feature where readers look for it. README introduces the product,
  CONTRIBUTING starts development, manuals explain use, specs define interfaces,
  and RFCs record design proposals. Source and measured behavior support claims.
- Keep instructions close to their authority. `AGENTS.md` is a thin entrypoint;
  the constitution owns coding-agent rules. Runtime prompts are separate files.
- A reviewable change includes its scope, effects, evidence and remaining limits.
  A passing compile, an installed binary and observed behavior prove different things.

## 1. Make a first contribution

Start at [CONTRIBUTING](../../CONTRIBUTING.md). For a documentation change, you do
not need the OCaml toolchain. Read the relevant source and linked manual before
editing a factual claim. For code, use the source prerequisites in
[README](../../README.md#from-source).

Choose an existing issue or write down the problem, expected result and how it
will be checked. Search issues, open/closed PRs and current source before starting:

```bash
gh issue list --repo jeong-sik/masc --state all --search "your topic"
gh pr list --repo jeong-sik/masc --state all --search "your topic"
rg "relevant_symbol" lib bin dashboard config docs
```

These commands require GitHub CLI authentication and ripgrep. GitHub's issue/PR
search and your editor's search work too. For a small fix, describe the reproduction
in the linked issue. Discuss a new public contract or broad architecture change
there before implementing it. If a PR already solves the problem, help review it.

With repository write access, use your existing clone:

```bash
git fetch origin main
git worktree add -b docs/your-topic ../masc-your-topic origin/main
cd ../masc-your-topic
```

Without write access, create a fork on GitHub first. Replace `YOUR-LOGIN` with your
GitHub account; the following starts from a new clone:

```bash
git clone https://github.com/YOUR-LOGIN/masc.git
cd masc
git remote add upstream https://github.com/jeong-sik/masc.git
git fetch upstream main
git worktree add -b docs/your-topic ../masc-your-topic upstream/main
cd ../masc-your-topic
```

Use `git remote -v` to check an existing clone instead of adding a duplicate remote.
Choose an unused directory. Keep runtime tests under a separate base path and
use a free port; the checkout and the workspace containing `.masc` are different.

For a first documentation patch, edit one factual claim and its translation where
present, run `bash scripts/check-doc-truth.sh` and `git diff --check`, and check the
changed links. Commit it, then `git push -u origin docs/your-topic`. Open a draft PR
to `jeong-sik/masc:main` using the template. Add `changelog.d/<PR number>.md` as
[CONTRIBUTING](../../CONTRIBUTING.md#pull-requests) describes, then push it before
marking ready. A useful summary explains the incorrect instruction, the correction,
and what was checked. Section 4 explains CI; maintainers handle fork integration.

### Find the source before editing

| Change | Read first | Source / verification entrypoints |
|---|---|---|
| Product documentation | [README](../../README.md), linked manual | `docs/`, `scripts/check-doc-truth.sh` |
| Keeper behavior or instructions | [Keeper manual](../KEEPER-USER-MANUAL.md), constitution | `lib/keeper/`, `config/prompts/keeper.md`, `test/` |
| Goal, Task, Board or completion | Constitution's domain rules | `lib/workspace/`, `config/tools/`, `test/` |
| Provider or lane behavior | Relevant interfaces and configuration | `lib/runtime/`, `lib/runtime_model/`, `test/` |
| TUI or browser UI | Existing interaction and payload contracts | `bin/masc_tui*.ml`, `lib/tui_decode.ml`, `dashboard/`, `test/` |
| CI or development policy | Constitution's execution protocol | `.github/workflows/`, `scripts/ci/`, `scripts/review/` |

This is a starting map, not a list of all affected files. Follow callers and tests,
and read any applicable scoped instructions before changing their area. Contract
changes and Keeper runtime prompt changes need separate reasoning and evidence.

## 2. Start an AI development session

Read [AGENTS.md](../../AGENTS.md) and the complete
[constitution](../constitution.xml) before planning or changing MASC. Then:

1. Confirm the checkout, branch, clean/dirty state and current main. Preserve
   existing work; use an isolated worktree when the shared checkout is in use.
2. Record the requested outcome, scope and required evidence. Read the actual
   source, current review comments and failing logs instead of relying on summaries.
3. Implement a bounded change. External coding sessions do not run local Dune
   builds; request CI at a finishing boundary. Use
   [linux-x64-probe](../../.github/workflows/linux-x64-probe.yml) when a test binary
   is needed. Release dispatch is for tag/RC work.
4. When moving to the next work unit, assign an adversarial review agent to the
   previous one. Review the findings yourself and address them. A subagent review
   is not automatically a cross-model review or a GitHub approval.
5. Leave the next concrete action and evidence when handing off.

AI-assisted contributions are welcome. The submitting author remains responsible
for understanding the diff, protecting credentials and private runtime data,
addressing reviews, and accurately describing the evidence. Identify what was
checked, by whom or by which agent, and what remains unverified. Generated output
and self-review alone do not establish runtime behavior or independent approval.

Keeper lanes may build/test locally if their toolchain exists. Those results do
not replace current-head PR checks or a targeted `test.yml` run. A session's
permissions, an MCP bearer identity and a Keeper's name are separate identities.
Do not reuse a shared Task owner to release another session's work.

## 3. Coordinate the work

GitHub Issues/PRs track the public change. MASC adds shared intent and execution:

| Record | Use |
|---|---|
| Issue | Problem, expected outcome, reproducible evidence and discussion |
| Goal | Shared outcome with a metric, observable measurement source and target |
| Task | Bounded implementation or review work, owner and completion contract |
| Board | Decisions, questions, dependencies and updates visible to the team |
| PR | Actual diff, validation, review and integration into main |

MASC participation is optional for an outside contributor. A public issue and PR
must be understandable without access to an operator's private workspace.
For goal-linked MASC work, create the Goal before its Tasks and pass `goal_id`
explicitly. Standalone Tasks are valid and can be linked to a Goal later.
Claim before starting. If another owner holds work, discuss or choose another
Task. On failure or handoff, release with a summary, evidence and next step.

Use the live session's tool schemas: `masc_goal_upsert`, `masc_add_task`,
`masc_transition` and `masc_board_post`. Tool schemas change; this guide does not
provide a second payload schema. Include IDs in public/private updates so readers
can follow the relationship. Treat a Board plan as a plan until it has evidence.

## 4. Validate and request CI

Pick checks from the changed behavior and its risks. Documentation work can run
`bash scripts/check-doc-truth.sh` and `git diff --check` without building OCaml.
Check new file links and anchors too. Human contributors can run focused local
checks; external coding-agent sessions follow section 2.

Open a draft using [scripts/pr-open.sh](../../scripts/pr-open.sh) or GitHub's fork
PR flow. Fill the [PR template](../../.github/pull_request_template.md), including
an issue link. Draft PRs skip the required PR-check jobs. When the diff and evidence
are ready, mark it ready for review to start required checks.

[pr-check.yml](../../.github/workflows/pr-check.yml) requires:

- dashboard typecheck;
- `dune build @check`, including selected tests;
- `dune build --profile release @check`;
- lint suite;
- TLA model check.

The workflow also reports the aggregate `PR required success`. Selection is not
a full behavior suite: inspect which tests the run actually executed.
[test.yml](../../.github/workflows/test.yml) provides scheduled/full runs and a
`workflow_dispatch` `suite` input for targeted verification, for example:

```bash
gh workflow run test.yml --repo jeong-sik/masc --ref your-branch \
  -f suite=test_keeper_meta_json_config_toml_only
```

Dispatch requires repository permission. Fork contributors can ask a maintainer
for the appropriate run. External agents do not watch/wait/poll CI; continue the
next contextual work unit and read results at a work boundary. When a check fails,
read the raw failure and determine whether it is your diff, the base, a timeout,
or a missing prerequisite. Avoid unrelated repairs inside the same PR.

## 5. Review and integrate

A reviewer reads the contract and diff, inspects behavior evidence and checks the
current PR head's completed run. Address each actionable finding with a change
or a source-backed explanation; resolve a thread only when its concern is handled.
Update the PR description when the scope, evidence or remaining risks change;
reviewers should not have to reconstruct the result from a comment chain.
A push creates a new head, so an earlier PASS does not certify the new one.
A reviewer who issued REQUEST_CHANGES must clear their own request once the
corrected head’s required checks pass.

MASC's structured decision line uses literal values:

```text
verdict: PASS|FAIL head: <40-character-current-SHA> run: <PR-check-run-id> by: <Keeper-name>
```

The line above is a format, not a verdict. Never publish placeholders as PASS.
Use [approve-guard.sh](../../scripts/review/approve-guard.sh) for APPROVE. The author
or a session that pushed the PR cannot independently approve it. Check main
freshness: overlapping changes to PR files or shared validation inputs require
integrating main and a fresh run. Read current reviews and issue comments again
before integration, including decisions posted after an earlier PASS.

Keepers handle merge. The constitution provides a limited exception for an
operator-launched external session using `jeong-sik`: all five current-head checks
must be completed and successful, and the read-only
[merge-guard](../../scripts/review/merge-guard.sh) must say `WOULD MERGE` with the
current head and run. Only then can that session use `gh pr merge --match-head-commit`.
External coding sessions do not use `--auto`, `--admin`, or the guard's merge mode.
Fork contributors hand integration to the maintainer; the same evidence rules apply.

Verify the merged commit and PR state before cleanup. Remove only the finished
worktree and branch after confirming they contain no unsubmitted work. Never push
a follow-up to a branch whose PR has merged; use a new branch and PR.

## 6. Submit evidence and resume later

For a MASC Task, use `submit_for_verification` with a handoff summary and evidence;
`done` is not a self-service completion action. Follow the live tool schema and
[evidence capture contract](../../lib/workspace/workspace_verification_store.mli)
for accepted references. A path/commit/PR mentioned in prose is not a snapshotted artifact.
Keep volatile test output as a bounded artifact, and provide a public URL or a
frozen Board/Fusion reference when the verifier needs to inspect it.

A Goal's measurement source must be something its completion judge can read.
The target must be comparable with that measurement. Finished Tasks or posts
announcing completion do not prove the Goal. Request completion with evidence;
verification and final human confirmation are separate stages.

A handoff records the Goal/Task/Issue/PR IDs, branch/worktree, current SHA, checks
already run, unresolved findings, blockers and next action. On resume, reread live
state before repeating mutations. Interrupted commands may already have applied.
Restore progress from saved records instead of changing runtime-owned files by hand.

## Maintaining these instructions

When a workflow, script, tool contract or runtime boundary changes, update the
relevant procedure in the same change. Keep command examples executable and
identify their prerequisites. Review the translated guide with the English guide.
Use the constitution to settle policy conflicts and source to settle implementation
claims; record an implementation gap rather than documenting an imagined guarantee.
