---- MODULE KeeperSwitchHierarchy ----
\* RFC-0107 Phase C.0 — Eio.Switch hierarchy model for keeper run_turn.
\*
\* Models the global Eio context (Eio_context.current_sw : Atomic.t) and
\* the proposed Option (2) "with_sw" atomic-swap wrap for run_turn body.
\*
\* Runtime truth being modelled:
\*   - On server startup, root_sw is set; current_sw := root_sw.
\*   - Two fiber roles run concurrently:
\*       * SERVER fibers (dashboard, board_dispatch, relation_materializer,
\*         autoresearch_codegen) — fork child work that MUST attach to root_sw
\*         (they outlive any single turn).
\*       * KEEPER fibers — execute run_turn. Inside run_turn, with_sw swaps
\*         current_sw := turn_sw, and resources created by keeper should
\*         attach to turn_sw (so they die when the turn ends).
\*   - Both roles read the *same global atomic* via get_switch_opt ().
\*
\* What this spec is FOR:
\*   - Invariant ServerResourcesOnRoot: every resource created by a SERVER
\*     fiber attaches to root_sw — never to turn_sw.
\*   - Invariant KeeperResourcesScoped: keeper resources created inside a
\*     turn attach to turn_sw, and after turn end either (a) the resource
\*     is released, or (b) the switch they attach to remains alive (impossible
\*     when turn_sw is closed → forces release).
\*
\* The *BUGGY* configuration (KeeperSwitchHierarchy-buggy.cfg) enables a
\* ServerForkDuringTurn action that lets a SERVER fiber read current_sw
\* *while it equals turn_sw*. The server resource then attaches to turn_sw
\* and survives past turn end → ServerResourcesOnRoot violated. This is the
\* concrete race that motivates Option (3) fiber-local or §2.1 root_sw_ref
\* mitigation (see RFC-0107-eio-context-switch-audit.md §5).
\*
\* This is the TLA+ Bug Model pattern (software-development.md §"TLA+ Bug
\* Model 패턴"): clean cfg must pass with no error; buggy cfg must violate
\* the invariant in a small number of steps.

EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    MaxTurns,        \* Upper bound on turns simulated.
    MaxResources     \* Upper bound on resources created per role per turn.

ASSUME MaxTurnsPos     == MaxTurns \in Nat /\ MaxTurns >= 1
ASSUME MaxResourcesPos == MaxResources \in Nat /\ MaxResources >= 1

(* ── Switch identity & state ───────────────────────────────────────── *)

SwitchIds == {"root_sw", "turn_sw"}

SwitchStates == {"alive", "closed"}

(* ── Resource (FD) identity & attachment ───────────────────────────── *)

\* role \in {"server","keeper"} — who created the resource.
\* attached \in SwitchIds — which switch owns its lifetime.

VARIABLES
    sw_state,        \* [SwitchIds -> SwitchStates]
    current_sw,      \* SwitchIds — the global atomic the runtime reads
    turn_phase,      \* "idle" | "in_turn"
    turns_used,      \* 0..MaxTurns — completed turn count
    resources        \* set of [id: Nat, role: {"server","keeper"}, attached: SwitchIds, released: BOOLEAN]

vars == << sw_state, current_sw, turn_phase, turns_used, resources >>

(* ── Type invariant ────────────────────────────────────────────────── *)

TypeOK ==
    /\ sw_state \in [SwitchIds -> SwitchStates]
    /\ current_sw \in SwitchIds
    /\ turn_phase \in {"idle", "in_turn"}
    /\ turns_used \in 0..MaxTurns
    /\ \A r \in resources:
         /\ r.id \in 0..(2 * MaxTurns * MaxResources)
         /\ r.role \in {"server","keeper"}
         /\ r.attached \in SwitchIds
         /\ r.released \in BOOLEAN

(* ── Initial state ─────────────────────────────────────────────────── *)

Init ==
    /\ sw_state = [s \in SwitchIds |-> IF s = "root_sw" THEN "alive" ELSE "closed"]
    /\ current_sw = "root_sw"
    /\ turn_phase = "idle"
    /\ turns_used = 0
    /\ resources = {}

(* ── Helpers ───────────────────────────────────────────────────────── *)

NextResourceId == Cardinality(resources)

ResourcesOnSwitch(s) ==
    { r \in resources : r.attached = s /\ ~r.released }

(* ── Actions (clean / common) ──────────────────────────────────────── *)

\* Server forks a child fiber. By the §2.1 intent, it MUST attach to root_sw.
\* In the CLEAN model, server reads current_sw only when turn_phase = "idle"
\* (guarded by some external invariant, e.g. fiber-local fallback). This is
\* what Option (3) gives us automatically.
ServerFork ==
    /\ turn_phase = "idle"
    /\ Cardinality(resources) < 2 * MaxTurns * MaxResources
    /\ resources' = resources \cup
         {[id |-> NextResourceId, role |-> "server",
           attached |-> current_sw, released |-> FALSE]}
    /\ UNCHANGED << sw_state, current_sw, turn_phase, turns_used >>

\* Keeper enters run_turn: with_sw turn_sw (...). Atomic swap + open turn_sw.
KeeperStartTurn ==
    /\ turn_phase = "idle"
    /\ turns_used < MaxTurns
    /\ turn_phase' = "in_turn"
    /\ current_sw' = "turn_sw"
    /\ sw_state' = [sw_state EXCEPT !["turn_sw"] = "alive"]
    /\ UNCHANGED << turns_used, resources >>

\* Keeper forks inside turn. attaches to current_sw (= turn_sw under wrap).
KeeperFork ==
    /\ turn_phase = "in_turn"
    /\ Cardinality(resources) < 2 * MaxTurns * MaxResources
    /\ resources' = resources \cup
         {[id |-> NextResourceId, role |-> "keeper",
           attached |-> current_sw, released |-> FALSE]}
    /\ UNCHANGED << sw_state, current_sw, turn_phase, turns_used >>

\* Keeper exits run_turn: closes turn_sw, restores current_sw := root_sw.
\* Any resource attached to turn_sw is *forcibly* released (Eio.Switch
\* contract: resources cannot outlive switch). We model this by setting
\* released := TRUE for all turn_sw resources.
KeeperEndTurn ==
    /\ turn_phase = "in_turn"
    /\ turn_phase' = "idle"
    /\ current_sw' = "root_sw"
    /\ sw_state' = [sw_state EXCEPT !["turn_sw"] = "closed"]
    /\ turns_used' = turns_used + 1
    /\ resources' =
         { IF r.attached = "turn_sw" /\ ~r.released
             THEN [r EXCEPT !.released = TRUE]
             ELSE r
           : r \in resources }

\* Voluntary release (e.g., HTTP request finished, FD closed cleanly).
ResourceRelease ==
    \E r \in resources:
       /\ ~r.released
       /\ resources' = (resources \ {r}) \cup {[r EXCEPT !.released = TRUE]}
       /\ UNCHANGED << sw_state, current_sw, turn_phase, turns_used >>

(* ── BUG action — race during turn ─────────────────────────────────── *)

\* SERVER fiber forks WHILE keeper is in turn. Reads current_sw = turn_sw,
\* attaches to turn_sw. Premature termination guaranteed when KeeperEndTurn
\* fires. This is the concrete §5 race scenario in the audit note.
ServerForkDuringTurn ==
    /\ turn_phase = "in_turn"
    /\ Cardinality(resources) < 2 * MaxTurns * MaxResources
    /\ resources' = resources \cup
         {[id |-> NextResourceId, role |-> "server",
           attached |-> current_sw, released |-> FALSE]}
    /\ UNCHANGED << sw_state, current_sw, turn_phase, turns_used >>

(* ── Next ──────────────────────────────────────────────────────────── *)

Next ==
    \/ ServerFork
    \/ KeeperStartTurn
    \/ KeeperFork
    \/ KeeperEndTurn
    \/ ResourceRelease

NextBuggy ==
    \/ Next
    \/ ServerForkDuringTurn

Spec      == Init /\ [][Next]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

(* ── Invariants ────────────────────────────────────────────────────── *)

\* Every SERVER resource attaches to root_sw. This is the §2.1 intent.
ServerResourcesOnRoot ==
    \A r \in resources:
       r.role = "server" => r.attached = "root_sw"

\* No live resource is attached to a closed switch.
NoLiveResourceOnClosedSwitch ==
    \A r \in resources:
       (~r.released) => sw_state[r.attached] = "alive"

\* Combined: the safety property we want.
SafetyInvariant ==
    /\ ServerResourcesOnRoot
    /\ NoLiveResourceOnClosedSwitch

====
