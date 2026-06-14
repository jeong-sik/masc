---
rfc: "0235"
title: "Stale-base revert guard: block PRs that silently revert recently-merged work"
status: Draft
created: 2026-06-14
updated: 2026-06-14
author: vincent
supersedes: []
superseded_by: null
related: []
implementation_prs: []
---

# RFC-0235: Stale-base revert guard

Status: Draft · A PR computed against a stale base must not be allowed to
silently drop work that merged onto main after it branched.
Drafted by: Claude (Opus 4.8, 1M), from the 2026-06-13 merge audit
(`~/me/reports/masc-merge-audit-2026-06-13.md`, finding task-947 /
cross-cutting structural defect).

> Anchors were read against `origin/main` (`f4fa00717`) on 2026-06-14.
> Line counts from the incident were measured with `git show` /
> `comm`, reproduced in §1.2.

---

## §1 Problem

### §1.1 A stale base can revert a sibling PR with no conflict

GitHub does not require a branch to be up to date before a squash-merge.
If PR-B branched from a base that predates PR-A, and PR-B carries the
pre-PR-A version of a file PR-A also changed, merging PR-B can drop
PR-A's lines. Git reports **no conflict** when the regions do not
textually clash, so nothing in the normal pipeline flags it. A
misleading PR title then hides the regression in review.

This is not hypothetical. On 2026-06-12, `6f5bfdeb2` (PR #20869, titled
`test(otel): fix rfc-0085 tests ...`) merged onto a main that already
contained three sibling PRs from ~3.5h earlier and reverted all three:

- #20853 — telemetry `Dated_jsonl` persistence
  (`lib/keeper/keeper_telemetry_consumer.ml:50`, the
  `Dated_jsonl.append store json` write the stale branch dropped),
- #20859 — gateway socket release before reconnect
  (`lib/gate/discord_gateway_state.ml:1`),
- #20848 — connector gateway state/status source.

The audit found four such stale-base reversions in a single 211-commit
window; the conveyor-belt merge cadence makes recurrence near-certain.

### §1.2 The detectable signal

The signal is *not* "the PR removes lines". It is: **main added lines to
a file the PR also modifies, since the PR's merge-base, and the PR's head
version of that file does not contain them.** Merging then drops them.

For the #20869 / #20853 pair this is exact — every line #20853 added to
the consumer was absent from the stale branch:

```
$ git show 7e051c947 -- lib/keeper/keeper_telemetry_consumer.ml \
    | grep '^+' | ... | sort -u            # lines #20853 added  -> 19
$ git show 6f5bfdeb2 -- lib/keeper/keeper_telemetry_consumer.ml \
    | grep '^-' | ... | sort -u            # lines #20869 removed -> 19
$ comm -12 added removed | wc -l           # intersection        -> 19
```

19 of 19. A run of significant added-on-main lines missing from the
branch is an unambiguous stale-base revert.

### §1.3 Why existing gates miss it

No current check in `.github/workflows/fundamental-check.yml` compares a
PR against the *intervening* main history. The content ratchets (e.g.
`fundamental-check.yml:315`, the `Fun.protect` guard) scan the PR's own
diff in isolation; "Detect Changed Surfaces" classifies surfaces, not
freshness. Branch-protection "require up to date" would force every PR to
rebase always — operationally heavy under admin-merge cadence and
bypassed by the keeper token anyway (the task-937 finding). What is
missing is a *scoped* freshness check that fires only on the dangerous
overlap.

---

## §2 Design

A CI gate, `scripts/ci/check-stale-base-revert.py`, wired as the
`stale-base-revert` job in `.github/workflows/fundamental-check.yml:349`
(`if: github.event_name == 'pull_request'`, `fetch-depth: 0`).

Given `--base` (the PR target tip, `pull_request.base.sha`) and `--head`:

1. `mb = git merge-base base head`.
2. `candidates = changed(mb, head) ∩ changed(mb, base)` — only files the
   PR *and* main both touched since divergence. A file the PR does not
   modify is kept by the 3-way merge and is never at risk, so it is
   excluded; this is what keeps the gate quiet on ordinary stale-but-safe
   branches.
3. For each candidate, `added = significant lines added in mb..base`,
   `missing = added \ lines(head:file)`.
4. If `|missing| ≥ REVERT_LINE_THRESHOLD` for any file → the branch is
   about to revert that file's recent additions. Fail, naming the file,
   the intervening commits, and sample missing lines.

This is a deterministic structural check on git objects — not a content
classifier or a telemetry counter. It blocks the defect; it does not
merely make it visible.

### §2.1 The remedy is always available

The fix is `git rebase origin/main`. Rebasing advances the merge-base
past the sibling commits, so `mb..base` no longer contains their
additions and the gate passes. Because the remedy is never a dead end,
the gate **blocks** rather than warns — an advisory-only gate is the
state that let #20869 through.

### §2.2 Opt-out for intentional reverts

A deliberate revert sets the PR label `stale-base-ack` (passed as
`PR_LABELS`); the gate then reports the reversal on stderr and passes.
The opt-out is a structured label, not a prose match on the PR body.

---

## §3 Threshold and false positives

`REVERT_LINE_THRESHOLD = 5` significant lines; `MIN_SIGNIFICANT_LEN = 10`
chars with at least one alnum (so `in`, `()`, closing braces — which
collide across unrelated code — carry no signal). The incident reversed
19; a handful is already decisive while leaving headroom for incidental
overlap on small edits.

False-positive shape: a legitimate refactor that genuinely removes ≥5
substantial lines a recent main commit added to the same file. The cost
is one rebase or one label — both cheap, both always available. The
guard is biased toward catching the silent revert.

## §4 Verification

`scripts/ci/test_check_stale_base_revert.py` rebuilds the stale-base
topology in throwaway git repos and asserts: stale-base PR → fail;
PR carrying main's additions → pass; PR editing a disjoint file → pass;
intentional revert with `stale-base-ack` → pass. Mutation-checked:
blinding the missing-line comparison flips the fire case to pass, so the
test pins real behavior. The job runs the self-test before the guard.

## §5 Limitations / scope

- Detection is line-set membership, so a moved (not deleted) block whose
  lines reappear elsewhere in the head file is treated as present. This
  is intentional — a moved line was not reverted.
- The gate does not address *why* squash-merge permits stale bases, nor
  branch-protection bypass (task-937); it is the scoped safety net, not
  the merge-policy change.
- Cross-file logical reverts (PR removes a caller of a symbol a sibling
  added in another file) are out of scope; the guard is per-file
  textual.
