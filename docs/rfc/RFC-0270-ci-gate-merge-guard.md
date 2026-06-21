---
rfc: "0270"
title: "CI Gate merge guard: block merges on a non-success CI Gate and trip on red main"
status: Draft
created: 2026-06-20
updated: 2026-06-20
author: vincent
supersedes: []
superseded_by: null
related: ["0235", "0250", "0260"]
implementation_prs: []
---

# RFC-0270: CI Gate merge guard

Status: Draft · A merge actor must not merge a PR whose required `CI Gate`
check is not `success`, and a red `main` must trip a guard rather than absorb
more merges. Tracked as issue #21757.

> Anchors read against `origin/main` (`2fd0673faf`) on 2026-06-20.
> Branch protection re-read via
> `gh api repos/jeong-sik/masc/branches/main/protection` at
> 2026-06-20T13:12:25Z.
> `lib/` line numbers shift; re-confirm against the merge-base before landing.

## 1. Problem

On 2026-06-20, `main` went red twice from the same defect class — an OCaml
warning 16 `[unerasable-optional-argument]`, a hard error under the CI
`warn-error` profile — and each time a red PR reached `main` while its required
check never reported `success`.

- 06:44 — #21750 (`feat(keeper): project delegation requests`) introduced
  `let digest_id ~requester ?goal ~topic ~reason =` in
  `lib/keeper/keeper_delegation_request.ml:62` (the `?goal` optional is followed
  only by labelled arguments, so it cannot be erased). Restored by #21768.
- Earlier the same day — #21714 introduced the same warning class in
  `lib/gate_keeper_backend.ml`, and #21721 left an unmatched `(match` in
  `lib/server/server_discord_in_process_gateway.ml`. Restored by #21739.

Both restore merges (#21739, #21768) were the second and third "restore main
build" actions of the day, crossing the `software-development.md` threshold of
"second fix of the same class → fix the process, not the call site." The CI
`warn-error` profile catches warning 16 at PR time, so each introducing PR was
red on its own branch CI. They reached `main` anyway because the merge gate has
three compounding holes.

**Hole 1 — `CI Gate` is the sole required status check.** `Build and Test`,
`Lint`, `Health`, and `Meta Guards` are advisory (non-required) by design;
`CI Gate` is meant to be the single authoritative aggregate.

```json
// Incident-time branch protection snapshot.
{ "required_status_checks": { "contexts": ["CI Gate"], "strict": false },
  "enforce_admins": false,
  "required_pull_request_reviews": { "required_approving_review_count": 0 } }
```

**Hole 2 — `CI Gate` resolves to `cancelled`, not `failure`, when the run is
cancelled.** The `ci-gate` job aggregates the advisory jobs and would fail on
`build=failure`, but its `if:` guard skips it entirely when the run is
cancelled, so the published check conclusion is `cancelled` — neither `success`
nor `failure`.

```yaml
# .github/workflows/ci.yml — job: ci-gate (name: "CI Gate")
needs: [pr-sync-check, pr-live-gate, changes, meta, build, lint, dashboard,
        health, structure-ratchet, shell-ir-ratchet, tla-specs]
if: ${{ always() && !cancelled() }}
```

**Hole 3 — incident-time `enforce_admins=false` let an admin (or a bot with
admin rights) merge while `CI Gate` ≠ success.** Merging closes the PR, which
cancels the in-flight run, which leaves `CI Gate=cancelled`. The red tree has
already landed, and no post-merge tripwire reverts it.

```yaml
# .github/workflows/ci-cancel-closed-pr.yml — on: pull_request_target: [closed]
# cancels queued/in_progress/pending pull_request runs for the closed PR head SHA
```

Sequence: an admin merges a red PR → the PR closes → `ci-cancel-closed-pr`
cancels the in-flight run → `CI Gate=cancelled` → the required check was never
`success`, but incident-time `enforce_admins=false` had already allowed the
merge.

This part is no longer an open option. Current repo state restores the #9738
boundary:

```json
// 2026-06-20T13:12:25Z
{ "required_status_checks": { "contexts": ["CI Gate"], "strict": false },
  "enforce_admins": true }
```

`scripts/ci/check-main-branch-protection.sh` also fails when
`.enforce_admins.enabled != true`, so `enforce_admins=true` is the live
invariant, not a future governance choice. A and D below are still required as
defense in depth: A stops bot merge attempts before they reach GitHub, and D
halts/reverts if `main` goes red through a direct push, future drift, or another
unwrapped path.

### 1.1 How masc issues a merge (and why there is no choke point today)

A keeper merges by running an arbitrary `gh pr merge` shell string through the
generic `execute` tool. The shell IR classifies that string into a typed
`Command_descriptor.Gh_pr_merge { pr_number; squash }`
(`lib/command_descriptor/command_descriptor.ml:127`, variant at `:3`;
`lib/ide/ide_event_types.ml:7`), but that classification is consumed **only
after execution, for observability** — `ide_bridge.ml:751`
(`ingest_pr_event_from_descriptor`, gated `if not success then ()` at line 735)
emits a `pr_state:"merged"` event for the dashboard. A repo-wide search finds
**no consumer of `Gh_pr_merge` on any pre-execution path**: the pure
pre-execution gate is `Approval_policy.decide (policy) ~caps:(Capability.t list)`
(`lib/exec/approval_policy.ml:158`), which decides on capabilities and never
sees the descriptor. So today there is no point — typed or otherwise — where the
merge command is checked against CI status before it runs.

The "conveyor" (the actor that auto-merges Draft PRs as bot `anyang-keepers`) is
named only in comments (for example `lib/exec/test/test_approval_policy.ml:349`,
describing how `git worktree remove` races "concurrent keepers/the conveyor").
No conveyor merge-issuing code is present in this repository; its location is
unconfirmed (§8).

### 1.2 Evidence — the bypass reproduced twice on 2026-06-20

Both introducing PRs were red on their own head SHA and merged anyway:

```
#21714  head e4211cc887   CI Gate=cancelled  Build and Test=failure  Lint=failure  Health=failure  Meta Guards=failure
#21750  head 444bdf0261   CI Gate=cancelled  Build and Test=failure  Lint=failure
```

`#21750` was `mergedBy: jeong-sik` (admin), merge commit `e19ad11fe9`. The
`cancelled` conclusion on the sole required check, paired with the
incident-time `enforce_admins=false`, is the exact bypass described above —
observed twice in one day.

## 2. Non-goals / boundary vs RFC-0235

This is not RFC-0235 (stale-base revert guard). RFC-0235 blocks a PR computed
against a stale base from silently dropping a sibling's already-merged lines —
there the PR is individually green and the defect is in the base it was diffed
against. Here the PRs are red on their own CI and merge anyway because the
required check concluded `cancelled`. The two guards are complementary and do
not overlap.

This RFC does not reopen the human admin-bypass decision. `enforce_admins=true`
is already the live branch-protection invariant and the repo has a drift guard
for it. The remaining scope here is the *bot* merge actors — keepers and the
conveyor — plus a post-merge red-main tripwire, both layered under the restored
server-side boundary.

## 3. Design constraints

- **Fail-closed only on an *unmet* required check, never on a legitimately
  cancelled run.** A run can be cancelled for reasons unrelated to a merge: a
  newer push supersedes an older run via the concurrency group. The guard keys
  on the *current head SHA's* latest `CI Gate` conclusion. A superseded older
  run for a previous SHA is irrelevant, because only the head SHA's latest run
  is inspected.
- **Distinguish "not yet success" from "rejected."** `success` ⇒ proceed;
  `failure`/`cancelled` ⇒ reject (do not merge); `pending`/`missing` ⇒
  retry-with-backoff up to a bounded timeout, then surface to the operator.
  Conflating `pending` with `failure` would stall valid merges; conflating
  `cancelled` with `pending` would re-admit the bypass.
- **Preserve bot throughput where it is safe.** The guard permits a bot merge
  whenever the head SHA's `CI Gate` is `success`. It blocks only `failure` and
  `cancelled`, and waits on `pending`/`missing`.
- **No check-query/merge TOCTOU.** The SHA whose `CI Gate` was observed must be
  the SHA that GitHub merges. If the PR head changes after the guard reads
  status, the merge command must fail and restart the guard on the new head
  rather than merging against stale evidence.
- **No telemetry-as-fix.** Counting bad merges is not the fix; the merge must be
  *prevented*, and red `main` must be *reverted or halted*, not merely surfaced.
- **Boundary enforcement, not symptom suppression.** A red `main` is a
  hard-invalid state — the build does not compile. The §4.2 tripwire reverts or
  halts on that invariant violation; it is not a cooldown, dedup, or repair that
  masks a recurring symptom. Per the `software-development.md` workaround bar,
  §4.1 (A) is the root fix; §4.2 (D) is a bounded backstop with an explicit
  removal target (§4.2).
- **Treat the all-actor root boundary as already restored.** A bot-layer guard
  is a meaningful reduction, but it is not equivalent to GitHub server-side
  enforcement. The repo already encodes that server-side boundary as
  `enforce_admins=true`; this RFC must not describe it as optional or future
  work. A and D are defense-in-depth under that invariant.

## 4. Proposed mechanism (A + D)

Two changes that close different holes; either alone leaves a gap.

### 4.1 A — Bot merge actors require `CI Gate == success` for the head SHA

Because no pre-execution merge gate exists today (§1.1), A is a *new* guard, not
a tweak to an existing check. It has two insertion points, one per bot actor:

1. **Keeper executor.** Add an effectful pre-execution guard in the keeper
   command-execution path that runs `gh pr merge`. When the shell IR classifies
   a command as `Command_descriptor.Gh_pr_merge`, the guard queries the PR head
   SHA's `CI Gate` conclusion and refuses to execute unless it is `success`:

   ```
   gh api repos/jeong-sik/masc/commits/<head_sha>/check-runs \
     --jq '[.check_runs[] | select(.name == "CI Gate")] | last | .conclusion'
   # success -> execute; failure/cancelled -> reject; pending/missing -> retry
   ```

   This guard cannot live in `Approval_policy.decide`, which is pure and cannot
   perform the check-runs I/O; it belongs in the effectful executor that runs
   the classified command. The `Gh_pr_merge` classifier
   (`command_descriptor.ml:127`) already recognizes the command shape, so the
   guard keys on that classification. The query uses the head SHA's *latest*
   `CI Gate` run (`| last`), satisfying the §3 superseded-run constraint.

   The guard must then pass that same SHA to the merge operation. With the
   current GitHub CLI (`gh version 2.87.3`, checked 2026-06-20), the supported
   flag is:

   ```
   gh pr merge <number> --squash --match-head-commit <head_sha>
   ```

   If `--match-head-commit` rejects because the PR head advanced between the
   check query and the merge request, the guard must not retry the same merge
   blindly. It restarts from PR metadata, reads the new head SHA, and waits for
   that SHA's `CI Gate == success`.

2. **Conveyor.** The auto-merge conveyor must apply the same precondition
   wherever it issues the merge. Its code is not in this repository (§1.1), so
   this RFC names the contract and §8 flags the ownership question.

A closes the bot-side path without changing branch protection. It does not
replace the `enforce_admins=true` baseline; it prevents keepers/conveyor from
attempting a doomed merge and gives the operator a typed, local rejection before
GitHub is asked to merge.

### 4.2 D — Post-merge tripwire on `main`

Even with A, a race (a merge that lands microseconds before its run reports, or
a future bypass path such as a human admin merge) can still leave `main` red. A
workflow on `push: main` first takes the conveyor halt/lock, then runs `Build
and Test`; on failure it:

- halts the conveyor (stops auto-merging onto a red tip), and
- opens a revert PR for the merge that turned `main` red (the merge commit whose
  first parent built green and whose tree is red), or pages an operator.

This bounds the "stayed red while more PRs merged" amplification — the cost that
turned single bad PRs into a fleet-wide block. Detection latency is explicit:
the halt/lock is emitted at workflow start, before the build verdict, so the
maximum additional conveyor merges after the `push: main` event is zero once the
workflow starts (excluding merges already in flight before the lock is acquired).
If the `push: main` workflow does not start within 5 minutes, a watchdog page is
the failure mode; if the build fails, the revert/page step must run immediately
after the failed `Build and Test` conclusion.

D is a bounded backstop, not a permanent valve. **Removal target:** once A covers
every bot merge actor (keeper executor landed and conveyor contract confirmed)
and branch-protection drift monitoring remains green, D's auto-revert reduces to
a halt-and-page alarm or is removed; the review is tied to the §8
conveyor-ownership and break-glass decisions.

### 4.3 Why not B/E alone, and where C now sits

- **B — promote `Build and Test` + `Lint` to required status checks.** Closes
  hole 1 at GitHub, but a required check that concludes `cancelled` is still not
  `failure`. B alone also does not stop a bot from attempting a merge before the
  aggregate decision is known.
- **E — set required-status `strict=true`.** This is useful stale-base hygiene:
  GitHub requires the PR branch to be up to date with `main` before required
  checks count. It does not close this incident class by itself. The bad heads
  were red on their own CI, and the bypass was a non-`success` aggregate
  conclusion plus merge timing/authority; `strict=true` does not turn
  `cancelled` into `failure`, does not enforce bot-side head-SHA matching, and
  does not halt a red `main` after an already-landed push. Treat it as a
  complementary branch-protection hardening, not a substitute for A+D.
- **C — `enforce_admins=true`.** This is no longer an alternative. It is the
  current branch-protection invariant and is enforced by
  `scripts/ci/check-main-branch-protection.sh`. A and D should be described as
  defense-in-depth under C, not as substitutes for it.

C + A + D is the layered closure: C is the server-side all-actor baseline, A
prevents known bot bad-merges before they reach GitHub, and D bounds the blast
radius if `main` still goes red through drift, direct push, or an unwrapped path.

### 4.4 Root-fix boundary for C

From an adversarial root-cause standard, C is the single server-side lever that
closes the bypass for every current and future merge issuer that uses an
admin-capable token. The repo already restored that lever:
`scripts/ci/check-main-branch-protection.sh` expects
`enforce_admins.enabled=true`, and live branch protection currently reports
`true`. Therefore a deployment must not claim that disabling C is equivalent to
the bot guard; any future disablement is branch-protection drift unless an
explicit break-glass exception is recorded.

The smallest server-side hardening is:

```
gh api -X POST repos/jeong-sik/masc/branches/main/protection/enforce_admins
```

Rollback is the corresponding DELETE on the same endpoint (§7). That rollback is
outside A/D and should be treated as an exceptional break-glass action, not as
normal RFC implementation rollback.

## 5. Implementation plan

1. **A, keeper executor:** add the effectful pre-execution guard described in
   §4.1(1) at the point where the classified command is executed (the executor
   that consumes `Command_descriptor.Gh_pr_merge`, currently only mirrored for
   telemetry at `ide_bridge.ml:751`). Reject a non-`success` `CI Gate` with a
   typed error surfaced to the keeper; treat `pending`/`missing` as
   retry-with-backoff. Execute only with `--match-head-commit <head_sha>` and
   restart the guard if GitHub reports a head mismatch. Tests: stub a
   check-runs response of `success`/`failure`/`cancelled`/`pending` → execute /
   reject / reject / retry; stub a head-advanced merge rejection → restart,
   never merge the stale SHA.
2. **A, conveyor:** locate the conveyor merge issuer (§8) and add the same
   precondition; if external, file the contract against its owner.
3. **D, tripwire workflow:** `.github/workflows/main-redline.yml` on `push: main`
   runs `Build and Test`; on failure it dispatches a conveyor-halt signal and
   opens a revert PR (or pages).
4. "Require `CI Gate == success`" and "treat `cancelled` as non-mergeable" are
   the same predicate stated two ways; the implementation keys on
   `conclusion == "success"`, which rejects `cancelled` and `failure` and
   distinguishes them from `pending`/`missing`.
5. **C, invariant monitoring:** keep `enforce_admins=true` as the branch
   protection invariant, keep `CI Gate` in the required contexts, and make the
   #9738 watchdog actionable when either drifts. This is the server-side layer
   that makes GitHub reject non-green admin merges without relying on each merge
   path being correctly wrapped.

## 6. Verification

- **Positive blocked:** a keeper attempting `gh pr merge` on a PR whose head SHA
  `CI Gate` is `failure` or `cancelled` is refused (unit test with stubbed
  check-runs).
- **Negative not blocked (no deadlock):** a PR whose head SHA `CI Gate` is
  `success` merges, even when an *older* superseded run for a previous SHA was
  `cancelled`. The guard inspects the head SHA's latest `CI Gate`.
- **TOCTOU blocked:** if the head SHA changes after `CI Gate == success` is
  observed but before merge, `--match-head-commit` rejects and the guard restarts
  against the new head. It must not merge using the stale success evidence.
- **Pending does not reject:** a head SHA `CI Gate` of `pending` causes
  retry-with-backoff, not a merge refusal, up to the bounded timeout.
- **Tripwire:** pushing a commit that fails `Build and Test` to `main` triggers
  `main-redline.yml`, which halts the conveyor before running the build and
  opens a revert PR after failure. If the push workflow does not start within 5
  minutes, the watchdog pages.
- **Regression guard:** replay the 2026-06-20 incidents (`#21714` head
  `e4211cc887` and `#21750` head `444bdf0261`, both `CI Gate=cancelled`) against
  the guard and assert the merge is refused.
- **C invariant:** live branch protection reports `enforce_admins=true` and
  required contexts include `CI Gate`; the #9738 drift script fails on any future
  deviation. Admin-bypass merge count remains zero against the §1.2 baseline.

## 7. Rollback

Each A/D change is independent and reversible: revert the keeper executor guard
(merges return to unconditional), delete `main-redline.yml` (tripwire off). No
data migration. Branch protection C is already governed by the #9738 invariant;
turning it off is a separate break-glass operation, not a normal rollback of
this RFC's bot guard or tripwire.

## 8. Open questions (governance)

- **Conveyor ownership:** where does the auto-merge conveyor issue its merge? It
  is named only in comments in this repository (§1.1) and merges as
  `anyang-keepers`; A's precondition must be added wherever that actor runs.
- **Break-glass process:** if an incident ever requires bypassing
  `enforce_admins=true`, what explicit approval/logging/re-enable procedure is
  required? Silent disablement would recreate the incident-time hole.
- **Revert vs halt on red main:** should D auto-open a revert PR, or only halt
  the conveyor and page an operator? Auto-revert is faster but can fight a human
  already fixing forward (as #21739 and #21768 did on 2026-06-20).

---

Drafted from the 2026-06-20 main-red investigation (issue #21757); the mechanism
in §1.1/§4.1 was corrected after an adversarial review found the original draft
mis-cited `ide_bridge.ml:751` (post-merge telemetry) as the merge path.
