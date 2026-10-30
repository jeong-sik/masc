---- MODULE KeeperFiberLocalSwitch ----
\* RFC-0107 Phase C.1 — Eio.Fiber.with_binding (Option 3) race-freedom proof.
\*
\* Companion to KeeperSwitchHierarchy.tla (Phase C.0, Option 2 model).
\* Where the Phase C.0 spec proved that Option 2 (atomic swap) is UNSAFE
\* under ServerForkDuringTurn, this spec proves that Option 3 (fiber-local
\* binding) is SAFE under the SAME race scenario — PROVIDED the audit §10.2
\* structural separation invariant holds: server fibers have no fiber-local
\* binding for sw_key.
\*
\* Runtime truth being modelled:
\*   - Each FIBER has its own fiber-local binding state (None or Some sw_id).
\*   - get_switch_opt logic:
\*       Fiber.get sw_key  OR  Atomic.get current_sw
\*     i.e. fiber-local first, atomic fallback.
\*   - server fibers DO NOT call with_turn_switch → their binding stays None.
\*     Reads always go to the atomic = server root_sw. (audit §10.2.)
\*   - keeper fibers DO call with_turn_switch → their binding = turn_sw
\*     during the turn body. Reads return turn_sw. After with_turn_switch
\*     exits, the binding returns to None (Eio.Fiber.with_binding contract).
\*
\* The crucial property: with_turn_switch does NOT touch the global atomic.
\* Server fibers reading get_switch_opt during a turn see root_sw via the
\* atomic fallback, NOT turn_sw. The §5 race scenario is gone by design.
\*
\* This is the TLA+ Bug Model pattern (software-development.md):
\*   - Clean cfg: ALL actions enabled (including ServerForkDuringTurn).
\*     Invariant SafetyInvariant holds. No counter-example.
\*   - Buggy cfg: ServerForkLeak action is added — a hypothetical world
\*     where a server fiber's binding is set to turn_sw (violating audit
\*     §10.2). Invariant SafetyInvariant is violated, showing that the
\*     audit §10.2 structural separation is what carries the safety
\*     argument. If a future refactor lets server fibers acquire a turn
\*     binding, this buggy cfg becomes the actual production model.

EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    MaxTurns,
    MaxResources

ASSUME MaxTurnsPos     == MaxTurns \in Nat /\ MaxTurns >= 1
ASSUME MaxResourcesPos == MaxResources \in Nat /\ MaxResources >= 1

(* ── Switch identity & state ───────────────────────────────────────── *)

SwitchIds    == {"root_sw", "turn_sw"}
SwitchStates == {"alive", "closed"}

\* Fiber-local binding: server fibers have NoBinding; keeper fibers inside
\* with_turn_switch have BoundTo(turn_sw). After exit, back to NoBinding.
\* In TLC we model binding as a flat string: "none" | "turn_sw".
BindingValues == {"none", "turn_sw"}

(* ── State ─────────────────────────────────────────────────────────── *)

VARIABLES
    sw_state,            \* [SwitchIds -> SwitchStates]
    current_sw_atomic,   \* SwitchIds — the GLOBAL atomic. In Option 3 this
                         \* never changes after init: it stays root_sw for
                         \* the server lifetime.
    keeper_binding,      \* BindingValues — fiber-local for the keeper fiber
    server_binding,      \* BindingValues — fiber-local for the server fiber
    turn_phase,
    turns_used,
    resources

vars == << sw_state, current_sw_atomic, keeper_binding, server_binding,
           turn_phase, turns_used, resources >>

(* ── Type invariant ────────────────────────────────────────────────── *)

TypeOK ==
    /\ sw_state \in [SwitchIds -> SwitchStates]
    /\ current_sw_atomic \in SwitchIds
    /\ keeper_binding \in BindingValues
    /\ server_binding \in BindingValues
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
    /\ current_sw_atomic = "root_sw"   \* WORM — Option 3 never overwrites
    /\ keeper_binding = "none"
    /\ server_binding = "none"          \* audit §10.2 invariant
    /\ turn_phase = "idle"
    /\ turns_used = 0
    /\ resources = {}

(* ── Helpers ───────────────────────────────────────────────────────── *)

NextResourceId == Cardinality(resources)

\* get_switch_opt for a fiber with binding [b]: fiber-local first, then
\* atomic fallback. Models eio_context.ml line ~95.
ResolveSwitch(b) ==
    IF b = "none" THEN current_sw_atomic
    ELSE b   \* binding is "turn_sw"

(* ── Actions ───────────────────────────────────────────────────────── *)

\* Server fiber forks a child. Server binding stays "none" (audit §10.2),
\* so get_switch_opt resolves to current_sw_atomic = root_sw. Attached
\* to root_sw → outlives any turn. CORRECT.
ServerFork ==
    /\ Cardinality(resources) < 2 * MaxTurns * MaxResources
    /\ LET resolved == ResolveSwitch(server_binding) IN
       resources' = resources \cup
         {[id |-> NextResourceId, role |-> "server",
           attached |-> resolved, released |-> FALSE]}
    /\ UNCHANGED << sw_state, current_sw_atomic, keeper_binding,
                    server_binding, turn_phase, turns_used >>

\* Keeper enters run_turn:
\*   Eio.Switch.run @@ fun turn_sw ->
\*   Eio_context.with_turn_switch turn_sw @@ fun () -> ...
\* turn_sw becomes "alive", keeper's fiber-local binding := turn_sw.
\* IMPORTANT: the GLOBAL atomic is NOT modified (Option 3 design).
KeeperStartTurn ==
    /\ turn_phase = "idle"
    /\ turns_used < MaxTurns
    /\ turn_phase' = "in_turn"
    /\ keeper_binding' = "turn_sw"
    /\ sw_state' = [sw_state EXCEPT !["turn_sw"] = "alive"]
    /\ UNCHANGED << current_sw_atomic, server_binding, turns_used, resources >>

\* Keeper forks inside the turn. Reads its OWN binding → "turn_sw" →
\* attaches to turn_sw. Forced release on KeeperEndTurn. Correct.
KeeperFork ==
    /\ turn_phase = "in_turn"
    /\ Cardinality(resources) < 2 * MaxTurns * MaxResources
    /\ LET resolved == ResolveSwitch(keeper_binding) IN
       resources' = resources \cup
         {[id |-> NextResourceId, role |-> "keeper",
           attached |-> resolved, released |-> FALSE]}
    /\ UNCHANGED << sw_state, current_sw_atomic, keeper_binding,
                    server_binding, turn_phase, turns_used >>

\* Keeper exits run_turn: with_turn_switch finally clears binding, then
\* Eio.Switch.run closes turn_sw, forcibly releasing turn_sw resources.
\* GLOBAL atomic still unchanged (Option 3).
KeeperEndTurn ==
    /\ turn_phase = "in_turn"
    /\ turn_phase' = "idle"
    /\ keeper_binding' = "none"
    /\ sw_state' = [sw_state EXCEPT !["turn_sw"] = "closed"]
    /\ turns_used' = turns_used + 1
    /\ resources' =
         { IF r.attached = "turn_sw" /\ ~r.released
             THEN [r EXCEPT !.released = TRUE]
             ELSE r
           : r \in resources }
    /\ UNCHANGED << current_sw_atomic, server_binding >>

\* Voluntary release.
ResourceRelease ==
    \E r \in resources:
       /\ ~r.released
       /\ resources' = (resources \ {r}) \cup {[r EXCEPT !.released = TRUE]}
       /\ UNCHANGED << sw_state, current_sw_atomic, keeper_binding,
                       server_binding, turn_phase, turns_used >>

\* SERVER fiber forks WHILE keeper is in turn. This is the §5 race
\* scenario from KeeperSwitchHierarchy.tla. Under Option 3:
\*   server_binding = "none" (audit §10.2 invariant) →
\*   ResolveSwitch("none") = current_sw_atomic = "root_sw" →
\*   server resource attaches to root_sw, NOT turn_sw.
\* The race is gone by design. Resource survives turn end. SAFE.
ServerForkDuringTurn ==
    /\ turn_phase = "in_turn"
    /\ Cardinality(resources) < 2 * MaxTurns * MaxResources
    /\ LET resolved == ResolveSwitch(server_binding) IN
       resources' = resources \cup
         {[id |-> NextResourceId, role |-> "server",
           attached |-> resolved, released |-> FALSE]}
    /\ UNCHANGED << sw_state, current_sw_atomic, keeper_binding,
                    server_binding, turn_phase, turns_used >>

(* ── BUG action — audit §10.2 violation ────────────────────────────── *)

\* A hypothetical refactor where the server fiber acquires a turn binding
\* (e.g. via a careless callback that crosses the fiber tree boundary).
\* This action shows what would happen if audit §10.2 STOPPED holding.
\* server_binding := "turn_sw". A subsequent ServerForkDuringTurn would
\* then attach to turn_sw → §5 race resurrected.
\* Enabled only in the buggy cfg.
ServerBindingLeak ==
    /\ turn_phase = "in_turn"
    /\ server_binding = "none"
    /\ server_binding' = "turn_sw"
    /\ UNCHANGED << sw_state, current_sw_atomic, keeper_binding,
                    turn_phase, turns_used, resources >>

(* ── Next ──────────────────────────────────────────────────────────── *)

Next ==
    \/ ServerFork
    \/ KeeperStartTurn
    \/ KeeperFork
    \/ KeeperEndTurn
    \/ ResourceRelease
    \/ ServerForkDuringTurn

NextBuggy ==
    \/ Next
    \/ ServerBindingLeak

Spec      == Init /\ [][Next]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

(* ── Invariants ────────────────────────────────────────────────────── *)

\* audit §10.2 structural invariant: server fibers never acquire a turn
\* binding. This is the load-bearing assumption of Option 3 safety.
ServerBindingAlwaysNone == server_binding = "none"

\* Atomic is WORM: never overwritten after server bootstrap.
AtomicWorm == current_sw_atomic = "root_sw"

\* Every SERVER resource attaches to root_sw. Same as Phase C.0 spec but
\* now this should hold UNDER ServerForkDuringTurn in the clean model.
ServerResourcesOnRoot ==
    \A r \in resources:
       r.role = "server" => r.attached = "root_sw"

\* No live resource is attached to a closed switch.
NoLiveResourceOnClosedSwitch ==
    \A r \in resources:
       (~r.released) => sw_state[r.attached] = "alive"

\* Combined safety: under audit §10.2, even the race scenario is safe.
SafetyInvariant ==
    /\ ServerResourcesOnRoot
    /\ NoLiveResourceOnClosedSwitch
    /\ AtomicWorm

====
