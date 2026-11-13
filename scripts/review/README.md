# Stack review admission

Review ordinary stacks from source. Review function, logic and code cleanliness;
approve when P0/P1/P2 are resolved and retain P3 for later. Source approval does
not wait for an Actions run. Release/Tag merge and publication decisions separately
require completed full verification for the candidate head.

Read the PR's current head, base, full diff and relevant source context. If the
reviewed change differs, review it again. The GitHub CLI can display the diff:

```sh
gh pr diff N --repo O/R
```

An independent reviewer can publish directly using the reviewed head:

```sh
gh api --method POST repos/O/R/pulls/N/reviews \
  -f event=APPROVE -f commit_id=HEAD_SHA
```

A reviewer must not approve their own change, and GitHub does not permit the PR author account to
approve its own PR. A commit author or committer account can be shared by
independent sessions; matching that account does not itself disqualify a review.
Read back the submitted review ID, state and commit ID. If publication or readback
is uncertain, inspect the existing effect before trying again.

A review's GitHub account, decision and commit ID do not establish which Keeper
session performed the review, which base and complete diff it saw, or a Release
CI run. Report the scope actually reviewed and distinguish unverified facts. Two Keepers
sharing a GitHub account do not create two authenticated account reviews.

## Reading current reviews

```sh
python3 scripts/review/github-reviews.py --repo O/R --pr N --head HEAD_SHA --gh gh
```

The command reads the PR and all review pages, then returns JSON with review IDs
in `approval_ids`, remaining `change_requests`, earlier
`superseded_change_requests`, `ambiguous_review_ids`, and provenance. It checks the PR identity before
and after the review read. Approval does not depend on account association or
review-body format. Exit 0 means at least one non-author approval on the requested
current head and no remaining change requests; exit 2
means those conditions or the requested head do not hold; exit 1 means the read
or review history could not be evaluated. It does not establish the independent
session, reviewed base/diff or Release run. A later formal approval replaces an
earlier change request by the same GitHub account; requests from other accounts
remain. COMMENTED and PENDING do not replace a formal decision, and a dismissed
review is not an approval. Matching approvals submitted in the same second count;
conflicting same-second decisions are shown as ambiguous for that account. A
duplicate review ID leaves the result unavailable. Do not infer ordering from IDs.
An unreadable or changed PR can be refused before an evaluation result exists;
in that case the command reports the reason on stderr rather than producing JSON.

Before using a later approval to conclude the code is ready, examine the original
concern and verify that it is actually addressed. A green CI result or approval
from a different account does not resolve another account's change request.
The native review state cannot automatically decide whether unstructured review
comments or other recorded blocking findings have been resolved; inspect them
before integration.

## Assigning and integrating reviews

`review-worklist.py` reads open PRs and review history to plan missing requests
across explicitly supplied GitHub logins. Its default is read-only; `--request`
publishes missing requests and reads the resulting state back:

```sh
python3 scripts/review/review-worklist.py --repo OWNER/REPO \
  --reviewer LOGIN_A --reviewer LOGIN_B
python3 scripts/review/review-worklist.py --repo OWNER/REPO \
  --reviewer LOGIN_A --reviewer LOGIN_B --request
```

An assignment is not an active or completed review. Preserve existing requests,
read the entire history and distinguish an unreadable snapshot from no work.
Each action's `current_head_submissions` preserves submitted reviews on that
exact head, including COMMENTED and DISMISSED, in API order. These are observations,
not approvals or proof of a completed source review. Missing comment identity or
submission time remains null; formal review decisions keep their existing rules.
Repository prompt changes do not themselves update a running Keeper's instructions.

Inspect REST `stack` metadata and ordered stack membership before selecting merge
scope. Every included PR requires its own reviewed current head and resolved
blocking findings. Recheck each head, base, complete diff and current reviews;
API failures are unknown.
**Merge a native stack whole, once, through its top PR; never merge it layer by
layer from the bottom.** Confirm the asynchronous result and all member PRs'
merged states. A non-native branch chain is handled parent first. See the
[Native GitHub Stacks guide](../../docs/guides/NATIVE-GITHUB-STACKS.md).

Release/Tag merge and publication decisions verify the completed Full CI run and
required jobs for that exact head. Record the run and review scope separately; a
native approval by itself proves neither. Source review, CI, merge, deployment
and observed runtime behavior are distinct evidence.

`queue-ledger.sh` reports review readiness and stack scope. The approved-candidate
preparation path combines explicitly selected heads without dispatching CI; it
still requires current reviews and scope checks. Missing Git objects are fetched
from the named repository. On a failed candidate publication, its incomplete
receipt and only a candidate ref still pointing to its own commit are removed.

Offline focused checks include `python3 -m unittest -v scripts/review/test_github_reviews.py`,
`test_review_worklist.py`, `test_queue_ledger.py` and `test_stack_scope.py`.

## The `merge` check on main

The `Approval auto-merge` workflow (`.github/workflows/approval-auto-merge.yml`)
has one job named `merge`. It runs on `workflow_run` of `Approval merge
request`, so its result is attached to the head of `main` at that moment. A red
`merge` there means one merge attempt ended red (a hold, a refused read, or a
read that stayed failed after `github-get.py`'s bounded retries); it is not a
failed build or test run, and it does not rerun itself. Successful `merge`
runs carry the same name, so read the job log before treating a red one as
`main` red.
