# Native GitHub Stacks

Before reviewing or merging a GitHub PR, distinguish its direct branch base from
its native stack base. `gh pr view --json baseRefName` alone cannot do this.
GitHub CLI and API capabilities change; check installed help and the official
[stack API contract](https://docs.github.com/en/pull-requests/reference/stacked-pull-requests-apis-and-webhooks).

## Read the merge scope

```bash
gh api repos/OWNER/REPO/pulls/NUMBER \
  --jq '{number, state, draft, head: .head.sha, base: .base, stack}'
# If stack is present, use stack.number (not stack.id):
gh api repos/OWNER/REPO/stacks/STACK_NUMBER
```

The PR's `stack` reports membership, position, size and stack base. The
[Stacks endpoint](https://docs.github.com/en/rest/pulls/stacks) returns ordered
`pull_requests`. For a selected PR, the merge scope includes every still-open
PR below it through that PR, excluding already merged entries and higher PRs.
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

A closed but unmerged downstack PR still blocks the selected PR. Only already
merged members can be excluded from new approval checks; closing a prerequisite
is not equivalent to merging it. See [closed middle PRs](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-stacked-pull-requests#you-closed-a-pull-request-in-the-middle-of-the-stack).

Use `scripts/review/merge-guard.sh --check --repo OWNER/REPO --pr NUMBER --head SHA`
to check the included scope. To inspect the read-only identity snapshot directly:

```bash
python3 scripts/review/stack-scope.py OWNER/REPO NUMBER SELECTED_CURRENT_HEAD
```

Re-read membership, stack base and all included
head/base identities before submission. If they changed, review the affected
changes again. Do not replace GitHub branch protection with the local verdict;
the server evaluates repository rules during the asynchronous operation.

## Submit and verify the result

For native stacks the API operation is:

```bash
gh api --method PUT repos/OWNER/REPO/pulls/NUMBER/merge-async \
  -f merge_method=squash -f sha=SELECTED_CURRENT_HEAD
```

This is a write affecting **all included downstack PRs**, not only NUMBER. Use
it only after the whole scope is reviewed and authorized. External coding agents
use the guard in read-only `--check` mode before this request. For non-native PRs,
use `gh pr merge --match-head-commit SHA` under the repository's normal procedure.
Do not use `--admin` or `--auto`.

The API's `sha` pins the selected head, not a client-supplied vector of all lower
heads. The final snapshot reduces races but is not an atomic all-head lock.
GitHub's server-side checks still apply. Receipt output labels the destination as the preflight target, not an accepted
destination: stack metadata may still change between that read and the request.
Capture the response's `details.uuid` and retrieve its result:

```bash
gh api repos/OWNER/REPO/pulls/NUMBER/merge-async/UUID
```

Acceptance is not a successful merge: at a work boundary, read that result and
confirm each included PR's merged state and merge commit. Report
queued, in progress, failed and merged distinctly; do not resubmit an uncertain
operation before reading its result. A stack operation is atomic for its included
group, as described in the official API contract.

After a partial stack merge, GitHub rebases the next unmerged PR onto the stack
base. Inspect the resulting identities instead of performing a parallel manual
retarget/rebase. See [merging native stacks](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/merging-stacked-pull-requests).

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
