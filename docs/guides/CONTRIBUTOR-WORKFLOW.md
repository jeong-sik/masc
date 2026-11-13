<p align="center">
  <img src="../assets/candle.svg" width="88" alt="MASC Keeper">
</p>

# Repository strategy and contributor workflow

[한국어](CONTRIBUTOR-WORKFLOW.ko.md) · [Contributing](../../CONTRIBUTING.md)

From a problem to a reviewed change, with evidence and a clear handoff.

| What brings you here? | Start here |
|---|---|
| **First contribution** | [Documentation · fork · first PR](#1-make-a-first-contribution) |
| **Develop with AI** | [Session setup · responsibility · execution boundaries](#2-start-an-ai-development-session) |
| **Team work** | [Issue · Goal · Task · Board](#3-coordinate-the-work) |
| **Verify a change** | [CI](#4-validate-and-request-ci) · [review and integration](#5-review-and-integrate) · [evidence and resume](#6-submit-evidence-and-resume-later) |

> [!NOTE]
> The [constitution](../constitution.xml), especially `execution_protocol`, owns
> the development contract. This guide explains how to apply it; workflow YAML
> and scripts show what is currently enforced.

```mermaid
flowchart LR
    A["Problem and issue"] --> B["Change on a separate branch"]
    B --> C["Draft PR"]
    C --> D["Independent source review"]
    D --> E["Integrate into main"]
```

## Repository strategy

- Work in stacked PRs created and maintained with `gh stack`. The bottom PR targets `main`; each later PR targets the
  preceding branch. Never merge another PR or `main` into a stack branch. Give each PR one concrete outcome.
- **Land a native stack whole, once, through its top PR. Never merge it layer by
  layer from the bottom**, including `merge-async` on a lower PR. Each partial
  merge moves `main` and makes the remaining layers, and other stacks, conflict again.
- When a stack conflicts with `main`, run `gh stack rebase` over the whole stack
  and push every layer once. Never push a fix to the bottom layer alone. Report
  conflicts per stack, not per bottom PR.
- Keep concurrent changes in separate worktrees. Task claims coordinate who is
  doing the work; they do not lock files or authorize editing another checkout.
- Put generated evidence and copied source snapshots under `artifacts/`. The root
  Dune file leaves that directory out of source discovery, so copied build
  stanzas and links inside it are never read. `.gitignore` alone does not stop
  Dune source discovery.
- For GitHub Native Stacks, inspect REST `stack` metadata and follow [Native GitHub Stacks](NATIVE-GITHUB-STACKS.md). Merge the top PR so the whole stack lands at once; a non-main direct base is not a parent-merge blocker. Review every PR in the stack.
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

### Check the problem and existing work

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

### Prepare a branch

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

### Your first documentation PR

For a first documentation patch, edit one factual claim and its translation where
present, check claims and changed links against source, and use `git diff --check`.
Commit it, then `git push -u origin docs/your-topic`. Open a draft PR
to `jeong-sik/masc:main` using the template. Add `changelog.d/<PR number>.md` as
[CONTRIBUTING](../../CONTRIBUTING.md#pull-requests) describes, then push it before
marking ready. A useful summary explains the incorrect instruction, the correction,
and what was checked. Section 4 explains CI; maintainers handle fork integration.

### Find the source before editing

| Change | Read first | Source / verification entrypoints |
|---|---|---|
| Product documentation | [README](../../README.md), linked manual | `docs/`, source for changed claims and links |
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
   builds. Ordinary stacks use source review. Request a development check only
   for a concrete need and keep its scope small; full CI belongs to the
   Release/Tag boundary. Do not watch or poll CI.
4. When moving to the next work unit, assign an adversarial review agent to the
   previous one. Review the findings yourself and address them. A subagent review
   is not automatically a cross-model review or a GitHub approval.
5. Leave the next concrete action and evidence when handing off.

AI-assisted contributions are welcome. The submitting author remains responsible
for understanding the diff, protecting credentials and private runtime data,
addressing reviews, and accurately describing the evidence. Identify what was
checked, by whom or by which agent, and what remains unverified. Generated output
and self-review alone do not establish runtime behavior or independent approval.

Keeper messages and delegation requests are visible to the operator in chat.
Write them with the same readable word spacing, punctuation and paragraph breaks
as a reply to the user, including natural Korean spacing. To shorten a request,
remove repetition or rewrite sentences; do not concatenate words. Preserve quoted
source text, code, paths and identifiers exactly.

**Commit boundary.** If `.githooks` is active, code commits run a local Dune
build in pre-commit. An external coding session following the no-local-build
rule uses `git -c core.hooksPath=/dev/null commit -m "your message"` for that
commit. This disables hooks for that command only, not future pushes: keep the
pre-push trace-leak guard active and obtain independent source review. Do not
change the clone's persistent hook configuration to avoid a build.

Keeper lanes may build/test locally if their toolchain exists. Those results do
not replace independent source review or full Release/Tag CI. A session's
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
Use `claim`, then `start` before implementation. If another owner holds work,
discuss or choose another Task. For your `Claimed` or `InProgress` Task, a handoff
uses `release` with a summary, evidence and next step. `AwaitingVerification`
cannot be released; leave its verification pending and record the handoff. If
abandoning a Task you own, `cancel` ends it with a reason, including while awaiting
verification. Cancellation does not count as completion.

Use the live session's tool schemas: `masc_goal_upsert`, `masc_add_task`,
`masc_transition` and `masc_board_post`. Tool schemas change; this guide does not
provide a second payload schema. Include IDs in public/private updates so readers
can follow the relationship. Treat a Board plan as a plan until it has evidence.

## 4. Validate and request CI

For existing shell and dashboard fixture checks, see [focused manual checks](FOCUSED-MANUAL-CHECKS.md). Choose the check for the changed boundary and preserve its stated evidence limits.

Choose evidence from the changed behavior and its concrete risks. For documentation,
read the source behind changed claims and check file links, anchors and commands.
`git diff --check` identifies whitespace errors; it does not establish behavior.
Human contributors can run focused local checks; external coding sessions follow
section 2. Prose wording, historical counts and source-style inventories are not
approval gates.

Open a draft using [scripts/pr-open.sh](../../scripts/pr-open.sh) or GitHub's fork
PR flow. Fill the [PR template](../../.github/pull_request_template.md), including
an issue link. Mark the PR ready when its diff and evidence are ready for review.
PR creation, pushes and ready transitions do not automatically start CI.

[pr-check.yml](../../.github/workflows/pr-check.yml) provides explicit source,
configuration and credential checks.
An optional exact-source native TUI dispatch also has a `workspace-files`
scenario for a matching server/TUI pair and focused file-read checks. Follow
[native TUI proof](NATIVE-TUI-PROOF.md); an artifact is not installation or
visible UI evidence.
[ci.yml](../../.github/workflows/ci.yml) builds only Core for the bottom PR,
with a focused build. Request these only when needed. The constitution's
"about two minutes" describes the intended scale, not a timeout or a pass/fail
threshold. A cold dependency cache can take longer; only an actual successful
completion is build evidence.

There is no automatic PR or general push CI. The operator-authorized
`main-minimal-build.yml` checks main every 30 minutes and builds four operator
executables only when non-documentation inputs lack a successful build receipt.
It reuses opam/Dune caches and records actual build SHA versus skipped scope;
it does not change ordinary review or Release/Tag requirements.
At `release/vX.Y.Z`, explicitly
freeze the included scope under [Release freeze](RELEASE-FREEZE.md); admit only
reviewed release-blocking repairs afterwards. Main updates belong to the next
version and do not require merging main into this candidate. Then explicitly
request [release-candidate.yml](../../.github/workflows/release-candidate.yml)
for full builds, type checks, behavior tests and installation verification on
that head. Tag publication also requires full checks and tests. See the
[CI and review workflow](../CI-REVIEW-WORKFLOW.md) for the authoritative procedure.

Dispatch requires repository permission; fork contributors can ask a maintainer
for an appropriate run. Continue useful work instead of watching or polling CI.
At a work boundary, read actual results and distinguish failures in the diff,
base or environment. Keep unrelated repairs in their own stack.

Choose focused checks by tracing changed files through the changed interface and
its direct consumers. Record `file → changed interface → direct consumer → actual
verification target → command and result`. A passing check that does not exercise
that consumer is not a substitute. This helps risk-based check selection; it does
not add a Core build or full CI admission requirement to every ordinary PR.

## 5. Review and integrate

Ordinary PRs targeting main have [operator-requested automatic merge](NATIVE-GITHUB-STACKS.md#operator-requested-automatic-merge)
enabled by default when Ready. Non-native PRs show GitHub's Auto-merge reservation
and use GitHub's valid-approval rules. Native stacks use the whole-scope worker
after two distinct accounts approve the exact current head of every unmerged
member. Use CHANGES_REQUESTED for blocking findings; COMMENTED prose is not an
automatic stop. Reviewers still inspect source before approving. Release/Tag
integration remains manual and requires full verification.

Choose work using the [PR patrol skill](../../.agents/skills/masc-pr-patrol/SKILL.md).
For MASC review requests, confirm the current code-review specialist Keepers and
their roles, then deliver the request to each intended Keeper through MASC Board,
Broadcast or a direct message exposed to the caller. Keeper callers use
`masc_keeper_delegate` with `target={kind:"keeper",name:"<Keeper>"}` and `prompt`;
operator or external clients can use `masc_keeper_msg` with `name` and `message`
when their tool surface exposes it. Check the caller's current capabilities.
Include the PR links, current head/base and Native Stack scope, requested review
perspective, verification evidence and remaining limits. A common Board packet
can hold that scope; if delivery to its intended Keepers is unconfirmed, send
each a direct message through the caller's available path, referring to the
packet. Read back the Board post or use `masc_keeper_delegate_status` with the
original target and operation ID, and record the target and receipt.
Acceptance or `queued` state proves submission, not review completion or approval.

For Broadcast, inspect and record the structured response's `request_id`, `seq`,
`mention`, `mention_delivery` and `fanout_state`. One broadcast routes one mention;
other `@` text does not prove delivery to every named Keeper. Count only the exact
target with `mention_delivery.kind=accepted` or `already_accepted` as accepted.
Keep passive, pending, deferred and rejected outcomes distinct; `ok=true` or
`fanout_state=finished` alone does not prove individual acceptance. When using a
broadcast as a common announcement, confirm each Keeper's request through a direct
message operation and its readback. Check existing effects before resending an
uncertain request.

GitHub user/team review requests also record account assignments; they do not
replace delivery to the intended Keepers or prove work has started or finished.
Use `scripts/review/review-worklist.py` with an explicit `--reviewer LOGIN` pool
to plan missing account requests, and add `--request` to publish them. Recheck
directly messaged PRs are still open. Changed-head CRs return to the Keepers who
actually wrote them, including when they share a GitHub account.

Review the contract and current-head diff from independent function, logic and
code-cleanliness perspectives. Approve when no P0/P1/P2 issue remains and collect
P3 findings for later. Ordinary review needs no CI run. State unverified behavior;
do not claim checks that were not run. Address each finding with a change or a
source-backed explanation and resolve a thread only when its concern is handled.
Update the PR description when scope, evidence or remaining risks change.

A push creates a new head, so earlier review does not certify new changes.
After rereview, a later formal approval replaces the earlier change request from
the same GitHub account. A request from another account remains open; a green CI
run or another account's approval does not resolve it. A current-head request
usually waits for author action, unless a rereview was explicitly requested.
Use submission times, not review IDs, to determine order. Missing times or a tie
for an account's latest formal decision leave the order unknown. A review body
or claimed Keeper name cannot authenticate which session used a shared account.
Consult the original concern and its owner when known; do not claim session
independence or a resolved finding solely from the account's later approval.

GitHub does not permit the PR author's account to approve its own PR. A commit's linked author or
committer account may be shared by independent Keeper sessions, so matching
that account does not disqualify a reviewer. The reviewing session must itself
be independent of the change; account identity alone cannot establish that.

Read the current head, base and complete diff before source review. With an
authenticated `gh` and `jq`, a reviewer can submit the result directly:

```bash
# Set repo and pr to the pull request being reviewed.
snapshot=$(gh api "repos/$repo/pulls/$pr")
head=$(printf '%s' "$snapshot" | jq -r '.head.sha')
gh pr diff "$pr" --repo "$repo"
# Review the diff and source context, then submit the reviewed head:
gh api --method POST "repos/$repo/pulls/$pr/reviews" \
  -f event=APPROVE -f commit_id="$head"
```

If the change differs, review it again. Once the source review passes, approve without waiting for CI;
Release merge and publication decisions separately require completed full CI.
After publication, read back review ID, state and commit ID. If publication or
readback is uncertain, inspect the existing effect before retrying. A GitHub
approval records the account, decision and commit ID; it does not establish
which session reviewed, the base or full diff that session saw, or a Release run.
Report what was actually reviewed and distinguish unverified facts.

An author or a session that pushed the PR cannot independently approve it.
For Release, record the completed full-verification run and the head it tested.

Read current reviews and comments again before integration. Outstanding blocking
reviews and later FAIL/HOLD decisions prevent integration; inspect comment
content and actual findings yourself because a native approval record cannot
automatically establish that unstructured concerns were addressed. Land a native stack
whole, once, through its top PR — never layer by layer from the bottom — and
review changes to both base and head before landing. A confirmed non-native
branch chain still lands parent first. Consult the current
[CI and review workflow](../CI-REVIEW-WORKFLOW.md). Ordinary stacks
use source review; a merge-compile record for the merge head is advisory.
Release heads require completed full CI. Fork contributors
hand integration to a maintainer. Source approval does not claim unobserved
build success or runtime behavior.

Verify the merged commit and PR state before cleanup. Remove only the finished
worktree and branch after confirming they contain no unsubmitted work. Never push
a follow-up to a branch whose PR has merged; use a new branch and PR.

Reuse review only within its recorded head, base, complete diff identity and scope.
Unchanged source files do not establish unchanged behavior when the base's
interfaces or consumers have changed. Keep ordinary and Release assessments under
the existing policy and do not extend execution evidence to unobserved scope.

## 6. Submit evidence and resume later

Use the [storage guide](WORKSPACE-STORAGE.md): new run output goes in repository
`artifacts/`; retain selected proof in `docs/evidence/`, investigations in
`docs/research/` and reports in `docs/reports/`.

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

When a contract conflicts with current policy, record the original contract,
policy clause, prior verdict and authorized change decision together before
deciding to retain, amend or retire it. Until that decision, do not submit evidence
for the new policy as satisfaction of the old contract.

Record execution completion, receipt acknowledgement and the current ledger
summary update separately, with timestamps and original evidence references.
Mark absent records unverified. Keep historical failures and decisions, but list
only remaining work as current pending state. On resume, read the actual Task, PR
and run before relying on a schedule or handoff. Measure ready-to-review,
fix-to-re-review, candidate-freeze-to-verification and completion-to-ledger-update
separately; before/after comparisons use the same definitions, sample scope and
count of unfinished samples.

## Maintaining these instructions

When a workflow, script, tool contract or runtime boundary changes, update the
relevant procedure in the same change. Keep command examples executable and
identify their prerequisites. Review the translated guide with the English guide.
Use the constitution to settle policy conflicts and source to settle implementation
claims; record an implementation gap rather than documenting an imagined guarantee.
