# Native GitHub Stacks

Before reviewing or merging a GitHub PR, distinguish its direct branch base from
its native stack base. `gh pr view --json baseRefName` alone cannot do this.
GitHub CLI and API capabilities change; check installed help and the official
[stack API contract](https://docs.github.com/en/pull-requests/reference/stacked-pull-requests-apis-and-webhooks).

## Build and maintain stacks with gh stack only

Create and maintain stacks with `gh stack` (`gh stack init`, `gh stack add`,
`gh stack submit`). Never pull another PR or main into a stack branch with a
merge: this repository squash-merges, so a merge adds ancestry without ever
removing it, chains grow by hundreds of commits ("Integrate current chat
repairs through PR #NNN"), and GitHub stops computing mergeability — the
2026-10-12 sweep found three PRs at `UNKNOWN` and five `DIRTY` from exactly
this pattern. When a layer conflicts, fix that layer and rebase the whole
stack (`gh stack rebase`); do not merge the moved base into the layer. A
branch-chain PR opened against its parent's branch becomes a native stack
only through the gh stack link; until then it merges layer by layer.

## Read the merge scope

```bash
gh api repos/OWNER/REPO/pulls/NUMBER \
  --jq '{number, state, draft, head: .head.sha, base: .base, stack}'
# If stack is present, use stack.number (not stack.id):
gh api repos/OWNER/REPO/stacks/STACK_NUMBER
```

The PR's `stack` reports membership, position, size and stack base. The
[Stacks endpoint](https://docs.github.com/en/rest/pulls/stacks) returns ordered
`pull_requests`.

**Merge a native stack whole, once, through its top PR. Never merge it layer by
layer from the bottom.** GitHub lets `merge-async` on a lower PR merge only the
PRs below it; do not use that. Each partial merge moves `main`, so the remaining
layers, and other stacks, conflict again. The merge scope is therefore every
still-open PR in the stack, read through its top PR.
Read each included PR's current identity and diff. Do not infer membership from
title, branch naming, or base chains when authoritative stack metadata exists.
An API error or missing CLI field is unknown state, not proof of no stack.

A non-main direct base is normal for a native stack. Do not demand separate
parent merges or manually retarget it to main. For an API-confirmed non-native
branch chain, land the parent first and inspect the resulting base/head changes.
Native stack bases need not be named main in other repositories. A native stack can
also target the branch of another open PR, including one in a different native
stack. Report the exact destination. Merging into that branch does not mean the
changes reached main, and the other stack is not automatically part of this
request. Follow that upstream relationship separately.

When scanning a repository, list all open PRs and native stacks before selecting
work. Preserve the difference between branch dependency, native membership and
source inclusion in an integration PR. Verify the latter against current commits
and file contents; a body naming an old canonical head is not evidence that the
latest original head is included. Annotate overlapping alternatives without
closing them or combining their scopes solely because titles look similar.

## Review all PRs that will merge

A source review of one PR certifies only that PR's inspected head and diff.
For a stack merge, every included PR needs its own current-head independent
approval, latest verdict and resolved blocking reviews. A lower draft, new head,
FAIL/HOLD or change request cannot be cleared by a clean leaf. Release heads also
need the full verification required by the repository. Ordinary MASC PRs do not
require an Actions run simply because they belong to a stack.

A reviewer can submit an ordinary GitHub APPROVE for the head they actually
reviewed. For each PR, inspect all review pages and the latest submitted formal state for each GitHub account. A
later formal approval replaces that account's earlier change request; a request
from another account remains. Comments and pending drafts do not clear requests.
An ambiguous or unreadable history is unknown. The review's `commit_id` binds
the GitHub decision to a head, but does not prove independent Keeper sessions,
the base or complete diff actually reviewed, or a Release CI run. Report the
scope that was actually reviewed and distinguish unverified facts.
Read review comments and assess outstanding findings before integration; the
native approval record cannot establish that unstructured concerns were resolved.

A closed but unmerged downstack PR still blocks the top PR. Only already
merged members can be excluded from new approval checks; closing a prerequisite
is not equivalent to merging it. See [closed middle PRs](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-stacked-pull-requests#you-closed-a-pull-request-in-the-middle-of-the-stack).

If a merge-compile observation is needed, it can be dispatched for the exact
top head after review (fire-and-forget, never watch or poll):

```bash
gh workflow run merge-compile.yml --ref main -f sha=TOP_PR_CURRENT_HEAD -f pr=TOP_PR_NUMBER
```

Re-read membership, stack base and all included head/base identities through
the GitHub endpoints above before submission. If they changed, review the
affected changes again. GitHub evaluates repository rules during the operation.

## Submit and verify the result

### Operator-requested automatic merge

Non-native Ready PRs targeting `main` have GitHub **Auto-merge enabled by
default** on creation/Ready transitions and subsequent review/lifecycle events.
The UI reservation waits for GitHub's two-approval rule; no one needs to click
the button. Drafts arm when marked Ready. Release branches stay manual.
Before extending an auto-merge-enabled standalone PR into a native stack or
retargeting its base, disable that reservation first. Native stack members use the whole-scope
worker instead of per-layer reservations; the worker clears existing reservations
when it observes native membership, Draft status, a non-main base or a release head.

For standalone reservations, GitHub determines which **two distinct account**
approvals remain valid, including dismissal after new reviewable changes.
An unchanged-diff rebase may retain approvals; the worker does not assert that
every retained standalone review has the new commit ID.

Native stacks merge after **two distinct GitHub accounts** have submitted APPROVE
with the exact current head as commit_id for every unmerged member. Repeated
approvals from one account count once. Author approvals, old heads, dismissed
reviews, outstanding change requests and ambiguous formal decisions do not
satisfy that worker admission. Reviewers still inspect source and outstanding findings
before approving. Record a blocking FAIL/HOLD as **CHANGES_REQUESTED**: automation
does not interpret COMMENTED review prose or establish Keeper-session independence.
Release branches retain manual full-CI admission.

[`approval-merge-request.yml`](../../.github/workflows/approval-merge-request.yml)
records a PR number on review and PR lifecycle events without a write token or
PR checkout. [`approval-auto-merge.yml`](../../.github/workflows/approval-auto-merge.yml)
runs the worker from its trusted default-branch workflow commit. It reads current
reviews and scope again and submits only the top PR of a native stack. GitHub
must enforce at least two approvals and stale-approval dismissal on `main`;
repository rules continue to apply during the actual merge. These metadata-only
workflows run no builds or tests.

The request workflow skips events that cannot change what the worker does: a
review or push on a draft, any event on a pull request that closed without
merging, a review on a closed pull request, a title or body edit, and a review
edit. A skipped request starts no runner and no worker job. Marking a draft
Ready reads its reviews again, so nothing submitted while it was a draft is
lost.

A worker run started by an event does not wait for an API quota. When a read
during admission meets one, the run records `rate_limited` with the server's
`retry_at`, requests no merge and exits with status 75. Nothing is lost:
[`approval-merge-sweep.yml`](../../.github/workflows/approval-merge-sweep.yml)
runs every 30 minutes, reads the open pull requests with one GraphQL walk and
runs the same worker on every scope that two accounts approved at its current
head and that is still open. The sweep decides nothing about merging; admission
stays in the worker. It skips a pull request with an auto-merge reservation
(GitHub merges that one itself), a conflicting one, and a native stack with a
layer that is not yet approved. It stops at the first worker run that meets a
quota and lists the scopes it did not reach; the next sweep takes them. Its
summary records the REST and GraphQL quota before and after.

The sweep also deletes branches a merge left behind. The worker deletes a head
branch when it sees the merge, which misses the layers of a native stack: each
is still the base of the open layer above it at that moment. A branch goes only
when a pull request of this repository that the worker merged ended at exactly
its tip and no open pull request has it as head or base. `main`, `release/*`
and any branch a protection rule or ruleset applies to stay. The open pull
requests are read again just before deleting, and the push carries a lease on
that tip, so a branch that moved is refused and kept.

At its next run the sweep reruns the worker on every scope that is still
approved and ready (`ready` and `select` in
`scripts/review/approval-merge-sweep.py`). A worker run that ended at the
quota, or failed on a transient GitHub answer such as "Base branch was
modified", therefore needs no follow-up. A refusal with a lasting reason, such
as a failing required check on a native stack, comes back at every sweep until
that reason is fixed. The sweep is scheduled every 30 minutes, and GitHub can
start a scheduled run late or, under heavy load, drop it. To recheck an
existing PR (any stack member) sooner, dispatch the worker by hand:

```bash
gh workflow run approval-auto-merge.yml --ref main -f pr=NUMBER
```

Local preflight is read-only with `GITHUB_EVENT_NAME=workflow_dispatch`,
`GITHUB_REPOSITORY=OWNER/REPO`, `DISPATCH_PR=NUMBER`, an authenticated `gh`, and
`python3 scripts/review/approval-auto-merge.py --dry-run`. After a merge request
is accepted, the worker follows its UUID and records member states;
pending/enqueued does not mean merged. A member read failure keeps that request
unsettled: the worker retries and hands off the same receipt if its wait ends.
Only a 404/410 from the UUID result endpoint ends tracking as `request_not_found`;
a terminal request failure retains its reason without requiring member reads.
A failed API read never establishes an absent stack or an approval.

GitHub's delete-branch-on-merge setting does not act on a merge made with the
Actions token, so the worker deletes the head branch of each pull request it
sees merged and records the outcome as `head_branches`. A branch stays when it
is the base of an open pull request, is a release branch, comes from a fork, or
received a commit after the merge (the delete push is leased on the merged
head). A failed delete is recorded and does not change the merge verdict.

GitHub also leaves a linked issue open when the merge is made with the Actions
token, so the worker closes the open issues that GitHub lists as closing
references of each pull request it sees merged, and records the outcome as
`linked_issues`. A pull request counts when its base is the default branch or
its merge commit is on that branch, so a layer of a landed native stack counts
although its base stays the parent branch.

Within one run, a merge closes each linked issue once. An issue stays open
when that run's check saw it reopened at or after the merge. Runs are not
serialized with each other: a run that checked before the reopening still
closes the issue (#51614), and the merge of a later pull request that links
the issue closes it again. A recheck of a merged pull request closes every
other open issue the pull request links: one whose close failed, one a
run left behind when it died before this step, and one that was never closed
because the pull request merged before the worker had this step. GitHub's
record does not tell the last kind from an issue left open on purpose. A
close that fails is recorded and does not change the merge verdict; the issue
stays open until the pull request is rechecked or someone closes it.

One GraphQL query reads every pull request of the scope. A second one is sent
only when a linked issue is still open; it asks whether the layers' merge
commits are on the default branch, and for each issue its state and when it
was last reopened. When the second query fails, the run closes no issue and
records each one.

GitHub decides what a closing reference is. `Closes #N` in a pull request
whose base is the default branch is one. GitHub documents that it ignores the
keyword in a pull request whose base is another branch, so a layer above the
bottom of a stack often lists none and the worker has nothing to close; the
Development section of the pull request's sidebar shows what GitHub
registered. The worker closes what the pull request declares: a pull request
that leaves work in an issue links it with `Relates #N`, the template's other
line.

The worker's GET transport retries a quota response only when GitHub provides
an actionable `Retry-After`, or zero `X-RateLimit-Remaining` with a future
`X-RateLimit-Reset`. It makes no request before that time. A pause restarts the
read-only admission or reservation plan, including head, base and review
checks; it never replays a merge or reservation write. An accepted merge keeps
its original UUID through read recovery. Other HTTP errors and missing or
conflicting quota headers remain visible failures.
When a quota wait reaches the existing follow deadline, the unsettled receipt
also carries its server `retry_at`. Each resumed run waits before its first GET
and preserves that time through further handoffs until the server allows reads.
Receipts without quota metadata keep their existing behavior.

### Manual integration

For native stacks the API operation is:

```bash
gh api --method PUT repos/OWNER/REPO/pulls/TOP_PR_NUMBER/merge-async \
  -f merge_method=squash -f sha=TOP_PR_CURRENT_HEAD
```

This is a write affecting **every PR in the stack**, not only the top PR. Use
it only after the whole scope is reviewed and authorized. For non-native PRs,
use `gh pr merge --match-head-commit SHA` under the repository's normal procedure.
Do not use `--admin` or `--auto`.

The API's `sha` pins the top PR's head, not a client-supplied vector of all lower
heads. The final snapshot reduces races but is not an atomic all-head lock.
GitHub's server-side checks still apply. Receipt output labels the destination as the preflight target, not an accepted
destination: stack metadata may still change between that read and the request.
Capture the response's `details.uuid` and retrieve its result:

```bash
gh api repos/OWNER/REPO/pulls/TOP_PR_NUMBER/merge-async/UUID
```

Acceptance is not a successful merge: at a work boundary, read that result and
confirm each included PR's merged state and merge commit. Report
queued, in progress, failed and merged distinctly; do not resubmit an uncertain
operation before reading its result. A stack operation is atomic for its included
group, as described in the official API contract.

## Resolve conflicts over the whole stack

When a native stack conflicts with its base, run `gh stack rebase` over the whole
stack and push every layer once (`gh stack push`, or one atomic push with a lease
per branch). Do not rebase or push the bottom layer alone and cascade the rest
later; collect a layer's fix as a commit or patch and restack once. Report the
conflict per stack ("stack #N conflicts with main, whole rebase needed"), not as
a problem of its bottom PR. See [merging native stacks](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/merging-stacked-pull-requests).

## Agent and Keeper context

`AGENTS.md` points coding agents here; `docs/constitution.xml` owns the repository
workflow. `config/prompts/keeper.md` independently teaches Keepers to inspect the
native API before judging merge scope. A repository edit does not update a running
Keeper server. For an operator-requested live change, verify `/health?full=1`'s
`paths.effective_base_path` and `paths.effective_masc_root`, read the current
`keeper` entry from `/api/v1/prompts`, preserve its effective text, and set the
operator override through the authenticated prompt API. Read it back and verify
the durable override. Do not edit managed prompt copies or unrelated Keeper role
instructions to substitute for a live override.
