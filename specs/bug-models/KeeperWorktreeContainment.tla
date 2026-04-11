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

NextBuggy ==
    \/ NextClean
    \/ \E k \in Keepers : CreateAtServerRoot(k)
    \/ \E k, v \in Keepers : CreateInOtherPlayground(k, v)

SpecClean == Init /\ [][NextClean]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* ---- Safety Invariant ---------------------------------------------
\*
\* Every recorded worktree must (a) live in a playground, and (b) be
\* owned by the keeper that created it. Anything else breaks the
\* containment invariant the trilogy is closing.

KeeperWorktreeContainment ==
    \A wt \in worktrees :
        /\ wt.location.kind = "playground"
        /\ wt.location.owner = wt.keeper

\* Type invariant for TLC sanity.
TypeOK ==
    /\ worktrees \in SUBSET [
           keeper : Keepers,
           location : [kind : {"playground", "server"}, owner : Keepers \union {NoOwner}]
       ]

====
