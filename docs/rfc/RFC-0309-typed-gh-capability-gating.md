---
rfc: "0309"
title: "Typed gh capability gating — active repo/discussion surfaces behind non-blocking HITL approval"
status: Draft
created: 2026-07-06
updated: 2026-07-06
author: vincent
supersedes: []
superseded_by: null
related: ["0254", "0255", "0304", "0303", "0160", "0208"]
implementation_prs: []
---

# RFC-0309: Typed gh capability gating

Status: Draft · Capability-plane redesign · Supersedes the behavior decision of
`docs/design/keeper-github-repo-create-discussion-policy.md` (PR #23362)
Drafted by: Claude (goal-matrix design session 2026-07-06), pending owner review.

> Anchors marked **(verified)** were read against `origin/main` @ `051506d8a7`
> on 2026-07-06. The G-0 baseline harness
> (`lib/exec/test/test_shell_ir_gh_capability_baseline.ml`, this RFC's W0 PR)
> pins every classification claim in §1 as an executable characterization test.

---

## §0 Summary

Keepers should be able to **actively** create GitHub repositories, open
Discussions, and comment on them — gated by an **asynchronous, non-blocking**
human approval step, not disabled. PR #23362 achieved safety by disabling both
surfaces and encoding that policy decision into the *risk* axis (factually
reversible operations were re-labeled `R2_Irreversible`). This RFC separates
the three axes that #23362 conflated:

| Axis | Question it answers | Owner after this RFC |
|------|--------------------|---------------------|
| **Risk** | Is this operation factually reversible? | `Shell_ir_risk` (typed verb family + word-list floor) |
| **Capability policy** | May *this keeper class* perform this verb family? | New `keeper_capability` policy table (G-5) |
| **Disposition** | Run / ask a human asynchronously / refuse? | `Verdict.t` incl. `Ask`, wired to the non-blocking HITL queue (G-6/G-7) |

The absolute constraint, set by the operator: **the tool gate must never block
a keeper turn.** An `Ask` verdict enqueues to the existing non-blocking
approval queue and the keeper yields. `Hitl_resolved` only wakes the keeper to
observe resolution state; it does not execute the command or install a grant.
Block-time p99 must be 0 ms (G-11/G-13) and the property is model-checked
(G-12).

---

## §1 Problem — three defects, one root

### Defect 1 — policy encoded as risk (#23362)

`repo_hosting_cli_irreversible_ops` now contains `("repo", ["create"; …;
"fork"])` and the entire `discussion` family (`lib/exec/shell_ir_risk.ml:284-296`
**(verified)**). `gh repo create` is factually reversible (a created repo can
be deleted); `gh discussion comment` is editable and deletable. Labeling them
`R2_Irreversible` makes the risk taxonomy assert falsehoods. The deny message
was reworded in the same PR to "repository-hosting CLI operation not permitted
**by policy**" (`lib/exec/verdict.ml:80-84` **(verified)**) — an in-code
admission that the axis being expressed is policy, not risk.

Why it matters beyond taste: every downstream consumer of `risk_class`
(receipts, dashboards, differential harness, future policy layers) now reads
"irreversible" for operations that are not. The next capability decision will
have to either pile onto the same lie or contradict it.

### Defect 2 — unknown gh verb auto-runs (Unknown → Permissive)

`classify_repo_hosting_cli` falls through to `R0_Read` when a subcommand
matches neither hand-maintained table (`lib/exec/shell_ir_risk.ml:478-479`
**(verified)**: `else if in_table … reversible … then R1 … else R0_Read`).
Under the autonomous overlay every risk class maps to `Observe` (auto-allow)
(`lib/exec/approval_config.ml:40-47` **(verified)**), so **a gh verb the word
lists have never heard of executes silently**. GitHub ships new verbs; each one
is fail-open until someone hand-edits a string list. This is the
Unknown→Permissive-Default anti-pattern the workspace guidelines name
explicitly.

### Defect 3 — binary disposition forces policy into risk

The approval floor only fires for `R2_Irreversible`/`Destructive_protected`
(`lib/exec/approval_policy.ml:161-171` **(verified)**), and the autonomous
overlay auto-allows everything else because — quoting the code — *"there is no
human or resolver in the loop to answer an [Ask]"*
(`lib/exec/approval_config.ml:40-47` **(verified)**). So the only lever
available to #23362 for "keeper must not do this unsupervised" was to relabel
the op R2. Meanwhile `Verdict.t` already has a 4-way disposition including
`Ask` (`lib/exec/verdict.mli:67-72` **(verified)**), and the keeper HITL
approval queue is already **non-blocking with a `Hitl_resolved` wake**
(`lib/keeper/keeper_approval_queue.ml:730, 841` **(verified)**). The resolver
the comment says doesn't exist *does* exist — it is simply not wired to the
exec gate. Wiring it is simultaneously the capability enabler and the
non-blocking guarantee.

**Root cause common to all three:** the system has one axis (risk) where it
needs three (risk × capability policy × disposition).

---

## §2 Boundary with RFC-0208 — what stays string-owned, and why

`risk_of_typed` deliberately abstains on `Gh` (`W (Gh _) -> R0_Read`,
`lib/exec/shell_ir_risk.ml:852-864` **(verified)**) with a documented
rationale: gh risk is *string-borne* — the HTTP method (`-X DELETE`), graphql
mutation bodies, and an evolving subcommand set live in argv strings, and an
earlier attempt to fake a typed opinion by round-tripping the IR mis-parsed
`-X DELETE` into a silent R0. That argument is correct **for risk**, and this
RFC does not reverse it:

- The word-list floor (`classify_words` → `classify_repo_hosting_cli`)
  **remains the owner of string-borne risk**: HTTP methods, graphql mutation
  fragments, positional-token sweeps.
- `classify` composes opinions with `max_risk (redirect) (max typed floor)`
  (`lib/exec/shell_ir_risk.ml:916-922` **(verified)**). A typed opinion can
  only *raise* the decision above the floor, never lower it. The
  under-classification hazard RFC-0208 fixed cannot re-enter through this RFC.
- What the typed layer takes over is **capability identity**, not risk
  arithmetic: *which verb family is this?* (`Pr`, `Issue`, `Repo`,
  `Discussion`, `Release`, `Api`, `Unknown of string`). That set is small,
  closed, and enumerable — exactly what GADTs are for — and it is the input
  the capability-policy axis needs. The `Unknown` constructor is the
  fail-closed replacement for today's `else R0_Read`.

**Delta vs. the 2026-07-06 goal-matrix document:** the matrix's pass criterion
"word-list membership 0" is narrowed here to: *capability-relevant gh verb
decisions are typed and exhaustive; unknown verbs are fail-closed; the
word-list floor for string-borne risk (methods, graphql bodies) is retained by
design.* The original criterion would have re-introduced the round-trip defect
RFC-0208 documents.

---

## §3 Design

### 3.1 Typed gh verb family (G-1..G-3)

Extend the existing `Gh` constructor's payload (or lower beside it) with a
parsed verb family:

```ocaml
(* Shell_ir_typed_types — sketch, final shape in W1 PR *)
type gh_repo_action =
  | Repo_view | Repo_list | Repo_clone
  | Repo_create | Repo_fork              (* reversible, external *)
  | Repo_edit | Repo_sync | Repo_set_default
  | Repo_delete | Repo_archive | Repo_transfer | Repo_rename  (* irreversible *)

type gh_discussion_action =
  | Discussion_create | Discussion_comment | Discussion_edit
  | Discussion_close | Discussion_reopen | Discussion_answer
  | Discussion_unanswer | Discussion_lock | Discussion_unlock
  | Discussion_delete                     (* irreversible *)

type gh_verb =
  | Gh_pr of gh_pr_action
  | Gh_issue of gh_issue_action
  | Gh_repo of gh_repo_action
  | Gh_discussion of gh_discussion_action
  | Gh_release of gh_release_action
  | Gh_api                                (* risk stays floor-owned *)
  | Gh_unknown of string                  (* fail-closed *)
```

Rules:

- Lowering is **from original argv at parse time** — no IR→words round-trip
  (the RFC-0208 hazard).
- `risk_of_typed` gives a **lower-bound** opinion from the verb
  (`Repo_delete → R2`, `Repo_create → R1`, `Gh_unknown → R2` fail-closed);
  the word-list floor still applies via `max_risk`, so `gh api -X DELETE`
  stays R2 regardless of the typed opinion.
- Walker/codegen coverage via `gen_shell_ir_walkers` (G-2) so new verbs force
  compile-time decisions everywhere.
- Exhaustive match in `risk_of_typed` — adding a verb without classifying it
  is a compile error, not a silent R0 (G-3).

### 3.2 Externality axis (G-4)

`Exec_effect.External_mutation` already exists but is coarse. Add a
reversibility-aware external effect so `Repo_create` carries
"external, reversible, durable-remote-surface" — the fact pattern the
capability policy keys on. Risk answers *can it be undone*; externality
answers *who can see it before it is undone*.

### 3.3 Capability policy axis (G-5)

A per-keeper-class table, orthogonal to risk:

```
capability          | autonomous keeper | supervised keeper | operator session
--------------------|-------------------|-------------------|------------------
gh_pr (create/edit) | Allow             | Allow             | Allow
gh_repo_create      | Requires_approval | Requires_approval | Allow
gh_discussion (mut) | Requires_approval | Allow             | Allow
gh_repo_delete etc. | Deny (floor)      | Deny (floor)      | Suggest_confirm
gh_unknown          | Requires_approval | Requires_approval | Suggest_confirm
```

(Values illustrative; the W2 PR fixes the table with the operator.)

### 3.4 Approval disposition (G-6..G-8) — the core

**Correction (W3/W4 implementation, verified against source).** The current
Shell IR gh capability path is intentionally enqueue-only. For
`Requires_approval`, the keeper-tool layer calls
`Keeper_approval_queue.submit_pending`, returns a typed pending/error payload to
the turn, and records block time as 0 ms. `on_resolution` records lifecycle
metrics/logs when an operator resolves the entry, and `Hitl_resolved` wakes the
keeper to observe the resolution. There is no same-turn wait, no stored
execution continuation, and no one-shot grant installed for a later retry.

W3/W4 deliver the **decision and enqueue layer**:

- `Gh_capability_policy.disposition_of` gives each gh verb a capability
  disposition (`Allowed | Requires_approval | Denied`), computed from the
  typed verb identity and the risk axis, orthogonal to the trust overlay.
- `Approval_policy.decide` consults it **between the catastrophic floor and the
  risk-graded trust overlay**: a `Requires_approval` gh verb produces
  `Verdict.Ask` **even under the autonomous (all-`Observe`) overlay**. This is
  additive — the layer only *adds* an approval requirement for gh, never
  removes one, and never touches non-gh commands.
- The keeper-tool runtime turns a gh capability `Ask` into a pending approval
  entry and returns immediately with structured pending state instead of
  auto-running or synchronously waiting.
- This makes the autonomous overlay's all-`Observe` rationale ("no resolver to
  answer an Ask") no longer a reason to auto-run gated gh: the verb now asks and
  stops at pending.

What this does **not** yet do (deliberately, pending a separate runtime
contract): approval resolution does not execute the stored command, install a
grant, or cause a retry to bypass policy. A future operator-resolve-to-execute
flow must add an explicit grant/continuation contract and tests before docs may
say approval enables the action.

- **Invariant (absolute):** no code path may *synchronously spin* on approval
  inside a domain. The current path returns immediately after enqueue; any future
  continuation path must preserve domain-non-blocking behavior. Enforcement
  targets (future waves): G-11 block-time metric (domain-occupancy p99 = 0 ms),
  G-12 TLA+ `NonBlockingApproval` invariant (clean + buggy cfg pair), G-13
  gated-op observability.

### 3.5 What #23362 got right and keeps

The genuine irreversibles stay floored exactly as before:
`repo delete/archive/transfer/rename`, `release delete`, `secret delete`,
`gh api -X DELETE`, `delete*` graphql mutations, `discussion delete`. The
catastrophic floor (`Deny`) remains trust-independent for these. This RFC widens
the space *between* Allow and Deny; for these ops it does not soften Deny.

> **W4/G-9 follow-up — `pr ready` and `pr merge` reclassified:** both were
> originally floored here. `pr ready` toggles a PR between draft and
> ready-for-review and is reversible via `gh pr ready --undo`; `pr merge` writes
> the base branch but is reversible via `git revert` (the tree is restored,
> exactly as a created repo can be deleted). Their high-stakes nature —
> CI/notifications for `ready`, base-branch/deploy effects for `merge` — is a
> durable-remote *externality* on the capability axis, not a reversibility fact
> (the same policy-as-risk conflation W4/G-9 closed for repo
> create/fork/discussion). Both now classify R1 in
> `repo_hosting_cli_reversible_mutations`. On the capability axis `pr ready` (not
> a durable-remote surface) stays `Allowed`, while `pr merge` (writes the shared
> base branch, `creates_durable_remote_surface`) is `Requires_approval` — routed
> to non-blocking human approval, mirroring `gh repo create` (2026-07-08 operator
> decision: merge asks, not denies). The baseline corpus, `test_gh_capability_policy`
> dispositions, and the destructive-floor regression tests were updated to match.

---

## §4 Goal matrix (G-0..G-13, six waves)

| Wave | Goal | Deliverable | Quantitative pass |
|------|------|-------------|-------------------|
| W0 | G-0 | Baseline harness `test_shell_ir_gh_capability_baseline.ml` + this RFC | corpus pinned; defect ledger counts asserted (delta-ratchet) |
| W1 | G-1 | typed gh verb family in `Shell_ir_typed_types` | verbs in §3.1 lower from argv; 0 IR→words round-trips |
| W1 | G-2 | `gen_shell_ir_walkers` coverage | walkers compile-fail on unhandled verb |
| W1 | G-3 | `risk_of_typed` exhaustive over verbs; `Gh_unknown → R2` fail-closed | unknown-verb auto-run count 0 (baseline: 4 pinned cases, incl. unknown action under a known family) |
| W2 | G-4 | reversible-external effect axis | `Repo_create` carries external+reversible effect |
| W2 | G-5 | `keeper_capability` policy table | policy decision readable without consulting risk |
| W3 | G-6 | `Requires_approval` disposition ≠ Deny | disposition round-trips through receipts |
| W3 | G-7 | exec gate `Ask` → HITL queue wiring | keeper-turn block time on gated op = 0 ms |
| W3 | G-8 | autonomous overlay: gated families → `Requires_approval` | overlay no longer all-`Observe` for gh mutations |
| W4 | G-9 | re-enable repo-create/discussion surfaces to request approval (supersede #23362 behavior; design doc marked superseded) | contract-valid `gh repo create OWNER/NAME --public\|--private\|--internal` reaches `Pending_approval`, not `Deny` |
| W4 | G-10 | repo-create capability contract (naming/ownership/lifecycle) | missing `OWNER/NAME`, missing/ambiguous visibility, or opaque repo target denies before HITL; valid requests carry structured contract metadata in the approval input |
| W4 | G-11 | prompts + `KEEPER-CAPABILITY-MATRIX.md` update; block-time metric | docs match behavior; p99 block-time 0 ms |
| W5 | G-12 | TLA+ `CatastrophicNeverAllowed` + `NonBlockingApproval` + `UnknownGhVerbNeverAutoRun` | clean cfg passes AND buggy cfg violates (both required) |
| W5 | G-13 | gated-op observability | 100% gated ops emit enqueue/resolve/wake events |

Wave order is dependency order: measurement (W0) → typed identity (W1) →
axes (W2) → disposition wiring (W3) → capability enable (W4) → formal +
observability closure (W5). G-9 must not land before G-7: enabling the
surfaces to request approval while `Ask` is unwired would reproduce #23362's
original dilemma.

---

## §5 Supersession of #23362

- `docs/design/keeper-github-repo-create-discussion-policy.md` remains the
  live decision **until G-9 lands**. The W4 PR flips its front-matter to
  `superseded_by: RFC-0309` in the same commit that changes behavior — docs
  and behavior never disagree.
- The #23362 word-list entries for `repo create/fork` and the reversible
  `discussion` mutations move out of `repo_hosting_cli_irreversible_ops` in
  W2/W4 (after the capability axis exists to receive them). Until then the
  baseline harness pins them as `DEFECT(policy-as-risk)` — deliberately
  failing loudly if anyone "fixes" them before the policy axis exists.
- Prompt lines added by #23362 ("Do not create GitHub repositories …") are
  replaced in G-11 with the approval-flow description.

## §6 Non-goals

- No removal of the word-list floor for string-borne risk (methods, graphql
  bodies, action-flags) — RFC-0208's boundary stands.
- No new GitHub credential materialization path; RFC-0008's retirement of the
  keeper-side credential provider is untouched.
- No synchronous approval waits anywhere, including "just this once" paths.
- No GitHub Discussions *read* tooling (separate decision).
- No change to MASC board semantics — the board remains the primary durable
  discussion plane; GitHub Discussions is for external-facing threads.

## §7 Rollback

Each wave is independently revertable. G-9 (behavior flip) is a single PR
whose revert restores #23362 semantics exactly; the axes and wiring beneath
it (W1–W3) are inert without it — they add typed structure and an unused
disposition, both of which fail closed.
