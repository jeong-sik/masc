---- MODULE KeeperWorktreeContainment ----
\* Bug Model: Keeper worktree containment (issue #6527).
\*
\* The MASC invariant being formalised: every worktree created by a
\* keeper must live inside that keeper's own playground bundle
\* (`.masc/playground/<keeper>/repos/<clone>/.worktrees/<name>/`).
\* Keepers must not create, read, or mutate worktrees that live at the
\* MASC server repository root or under another keeper's playground.
\*
\* This spec models only the worktree-creation surface — enough to
\* distinguish:
\*
\*   a) the legitimate path (Iter-2 onwards): `CreateInOwnPlayground`
\*   b) the old server-root fallback (removed in PR #6542):
\*      `CreateAtServerRoot`
\*   c) the workspace-default `.worktrees/` and pr_submit leak (closed
\*      in Iter-4, PR #6580): `CreateInOtherPlayground`
\*
\* Two specs are defined:
\*
\*   * `SpecClean` — only the legitimate action. `KeeperWorktreeContainment`
\*     holds. TLC should report "no error".
\*   * `SpecBuggy` — the legitimate action plus both leak actions.
\*     `KeeperWorktreeContainment` is violated in one step.
\*
\* If the clean spec ever fails or the buggy spec ever passes,
\* something has regressed in iter 2 / iter 4.

EXTENDS Naturals, FiniteSets

CONSTANTS Keepers    \* Set of keeper names (small finite symmetry set for TLC)

\* ---- State ---------------------------------------------------------
\*
\* A worktree is recorded as a pair [keeper, location].
\* `keeper`     is the keeper that invoked masc_worktree_create.
\* `location`   describes where the worktree was materialised:
\*   `[kind |-> "playground", owner |-> k]` — inside keeper `k`'s
\*                                            own playground bundle
\*   `[kind |-> "server",     owner |-> "none"]` — at the MASC server
\*                                            repository root (the
\*                                            pre-#6542 fallback)

NoOwner == "none"

VARIABLE worktrees

vars == <<worktrees>>

Init ==
    worktrees = {}

\* ---- Actions -------------------------------------------------------

\* Legitimate action: keeper `k` creates a worktree inside its own
\* playground bundle. This is the only action in the clean spec.
CreateInOwnPlayground(k) ==
    /\ k \in Keepers
    /\ worktrees' = worktrees \union
           {[keeper   |-> k,
             location |-> [kind |-> "playground", owner |-> k]]}

\* Bug action: the old `worktree_create_r` server-root fallback
\* (removed in PR #6542). Keeper `k` ends up with a worktree at the
\* MASC server repository root — not inside any playground.
CreateAtServerRoot(k) ==
    /\ k \in Keepers
    /\ worktrees' = worktrees \union
           {[keeper   |-> k,
             location |-> [kind |-> "server", owner |-> NoOwner]]}

\* Bug action: the `.worktrees/` workspace-default leak and the
\* keeper_pr_submit cross-keeper cwd leak (both closed in PR #6580).
\* Keeper `k` operates inside keeper `victim`'s playground bundle even
\* though `victim /= k`.
CreateInOtherPlayground(k, victim) ==
    /\ k \in Keepers
    /\ victim \in Keepers
    /\ k # victim
    /\ worktrees' = worktrees \union
           {[keeper   |-> k,
             location |-> [kind |-> "playground", owner |-> victim]]}

\* ---- Transitions ---------------------------------------------------

NextClean ==
    \/ \E k \in Keepers : CreateInOwnPlayground(k)

\* Buggy variant 1: adds the pre-#6542 server-root fallback.
\* Violates KeeperWorktreeKind (and by conjunction
\* KeeperWorktreeContainment). Used by
\* [KeeperWorktreeContainment-server-root-buggy.cfg].
NextBuggyServerRoot ==
    \/ NextClean
    \/ \E k \in Keepers : CreateAtServerRoot(k)

\* Buggy variant 2: adds the pre-#6580 cross-keeper playground leak.
\* Violates KeeperWorktreeOwner (but NOT KeeperWorktreeKind). This is
\* why the cfgs must list BOTH invariants: if only KeeperWorktreeKind
\* were checked, this bug action would slip through.
\* Used by [KeeperWorktreeContainment-other-playground-buggy.cfg].
NextBuggyOtherPlayground ==
    \/ NextClean
    \/ \E k, v \in Keepers : CreateInOtherPlayground(k, v)

SpecClean                == Init /\ [][NextClean]_vars
SpecBuggyServerRoot      == Init /\ [][NextBuggyServerRoot]_vars
SpecBuggyOtherPlayground == Init /\ [][NextBuggyOtherPlayground]_vars

\* ---- Safety Invariants --------------------------------------------
\*
\* Two independent invariants. They are split intentionally so a
\* future refactor cannot silently weaken the spec by dropping one of
\* the conjuncts from a joint invariant. Each cfg must list BOTH:
\*
\*   1. `KeeperWorktreeKind`  — every worktree lives in a playground
\*                              (never in the server repository root)
\*   2. `KeeperWorktreeOwner` — the playground is owned by the keeper
\*                              that created the worktree (not by
\*                              another keeper)
\*
\* If a future commit drops `KeeperWorktreeOwner`, the buggy
\* spec's `CreateInOtherPlayground` action will NOT be caught (because
\* `kind = "playground"` still holds). Splitting forces the spec to
\* carry both checks and makes any dropped invariant surface as a
\* cfg-level change reviewers can notice.

KeeperWorktreeKind ==
    \A wt \in worktrees :
        wt.location.kind = "playground"

KeeperWorktreeOwner ==
    \A wt \in worktrees :
        wt.location.owner = wt.keeper

\* Combined invariant — kept for compat with the original PR body
\* and the bug-model registry script. Consumers should still list
\* KeeperWorktreeKind and KeeperWorktreeOwner individually in the
\* cfg so neither can be silently dropped.
KeeperWorktreeContainment ==
    /\ KeeperWorktreeKind
    /\ KeeperWorktreeOwner

\* Type invariant for TLC sanity.
TypeOK ==
    /\ worktrees \in SUBSET [
           keeper : Keepers,
           location : [kind : {"playground", "server"}, owner : Keepers \union {NoOwner}]
       ]

====
