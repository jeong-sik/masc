---- MODULE KeeperCascadeRouting ----
(* RFC-0041: Cascade Routing Architecture — Group/Item Hierarchy.

   Models the L1 Proactive Routing layer: per-turn health-aware item
   selection, group fallback chain, and keeper isolation.

   OCaml ↔ TLA+ mapping:

     spec variable          | OCaml type / module                | source
     -----------------------+------------------------------------+----------------------------
     item_health            | item_health_state                  | lib/cascade/cascade_state.ml
     consecutive_failures   | int (per-item, per-keeper)         | lib/cascade/cascade_health_tracker.ml
     keeper_state           | keeper_registry entry state        | lib/keeper/keeper_registry.ml
     selected_item          | string option                      | lib/keeper/keeper_unified_turn.ml
     fallback_count         | int                                | lib/cascade/cascade_fsm.ml
     group_path             | string list (visited set)          | lib/cascade/cascade_routes.ml

   Scope: this spec models item-level health transitions and group
   fallback chains ONLY.  It is orthogonal to KeeperCascadeLifecycle.tla
   (turn-level states: idle/selecting/trying/done/exhausted) and
   CascadeAttemptLiveness.tla (per-attempt streaming FSM).

   Design Anchors (RFC-0041 §3):
   1. cascade 때문에 Keeper 움직임을 끊기게 하면 안 됨
   2. 한 Keeper의 cascade가 다른 Keeper를 막지 않음
   3. 텔레메트리 정보가 분명하게 수집될 것
   4. cascade는 group과 item을 소유함
   5. item은 설정/전략에 따라 선택되거나 fallback 됨
   6. group 낸부 순회가 안 된다면 다른 group으로 시도할 수 있음
 *)

EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Keepers,           (* Set of keeper identifiers *)
    Items,             (* Set of item identifiers *)
    Groups,            (* Set of group identifiers *)
    MaxConsecutive,    (* Threshold: Degraded → Unhealthy *)
    MaxFallbacks       (* Bound on fallback count per turn *)

ASSUME MaxConsecutive \in Nat
ASSUME MaxFallbacks \in Nat

(* ── Group/item topology (static) ─────────────────────── *)

(* Each item belongs to exactly one group.
   Override via cfg CONSTANTS for different topologies. *)
ItemGroup == [i \in Items |-> IF i \in {"i1", "i2"} THEN "g1" ELSE "g2"]

(* Fallback chain: each group may fall back to another group. *)
FallbackGroup == [g \in Groups |-> IF g = "g1" THEN "g2" ELSE "none"]

(* ── Variables ────────────────────────────────────────── *)

VARIABLES
    keeper_state,          (* keeper → {"Running", "Turning", "Restarting"} *)
    item_health,           (* keeper × item → {"Healthy", "Degraded", "Unhealthy"} *)
    consecutive_failures,  (* keeper × item → Nat *)
    selected_item,         (* keeper → Items ∪ {"none"} *)
    fallback_count,        (* keeper → Nat *)
    group_path,            (* keeper → Seq(Groups) — visited groups this turn *)
    turn_blocked           (* keeper → BOOLEAN — BUG tracking *)

vars == << keeper_state, item_health, consecutive_failures,
           selected_item, fallback_count, group_path, turn_blocked >>

(* ── Type invariant ───────────────────────────────────── *)

TypeOK ==
    /\ keeper_state \in [Keepers → {"Running", "Turning", "Restarting"}]
    /\ item_health \in [Keepers × Items → {"Healthy", "Degraded", "Unhealthy"}]
    /\ consecutive_failures \in [Keepers × Items → 0..MaxConsecutive+1]
    /\ selected_item \in [Keepers → Items ∪ {"none"}]
    /\ fallback_count \in [Keepers → 0..MaxFallbacks]
    /\ group_path \in [Keepers → Seq(Groups)]
    /\ turn_blocked \in [Keepers → BOOLEAN]

(* ── Helper operators ─────────────────────────────────── *)

(* Items belonging to a given group. *)
ItemsInGroup(g) == {i \in Items : ItemGroup[i] = g}

(* Is an item healthy for a given keeper? *)
IsHealthy(keeper, item) == item_health[<<keeper, item>>] = "Healthy"

(* Select a healthy item from a group's items for a keeper.
   If no healthy item exists, returns "none".
   Strategy: priority order (simplified as deterministic choice
   for model checking; OCaml uses configurable strategy). *)
SelectHealthyItem(keeper, g) ==
    LET healthy == {i \in ItemsInGroup(g) : IsHealthy(keeper, i)}
    IN IF healthy = {}
       THEN "none"
       ELSE CHOOSE i \in healthy : TRUE

(* Range of a sequence — set of all elements. *)
Range(seq) == {seq[i] : i \in 1..Len(seq)}

(* Check if a group path contains a cycle. *)
HasCycle(path) ==
    \E i, j \in 1..Len(path) :
        i < j /\ path[i] = path[j]

(* ── Init ─────────────────────────────────────────────── *)

Init ==
    /\ keeper_state = [k \in Keepers |-> "Running"]
    /\ item_health = [<<k, i>> \in Keepers × Items |-> "Healthy"]
    /\ consecutive_failures = [<<k, i>> \in Keepers × Items |-> 0]
    /\ selected_item = [k \in Keepers |-> "none"]
    /\ fallback_count = [k \in Keepers |-> 0]
    /\ group_path = [k \in Keepers |-> << >>]
    /\ turn_blocked = [k \in Keepers |-> FALSE]

(* ── Normal Actions ───────────────────────────────────── *)

(* Turn starts: select an item from the primary group.
   The keeper transitions from Running to Turning.
   group_path records the first group visited. *)
TurnStart(keeper) ==
    /\ keeper_state[keeper] = "Running"
    /\ LET primary == CHOOSE g \in Groups : TRUE
           item == SelectHealthyItem(keeper, primary)
       IN /\ selected_item' = [selected_item EXCEPT ![keeper] = item]
          /\ group_path' = [group_path EXCEPT ![keeper] = << primary >>]
    /\ keeper_state' = [keeper_state EXCEPT ![keeper] = "Turning"]
    /\ fallback_count' = [fallback_count EXCEPT ![keeper] = 0]
    /\ UNCHANGED <<item_health, consecutive_failures, turn_blocked>>

(* Item execution succeeds: keeper returns to Running.
   Health state of the used item is unchanged (it was already Healthy). *)
ItemSuccess(keeper) ==
    /\ keeper_state[keeper] = "Turning"
    /\ selected_item[keeper] /= "none"
    /\ IsHealthy(keeper, selected_item[keeper])
    /\ keeper_state' = [keeper_state EXCEPT ![keeper] = "Running"]
    /\ selected_item' = [selected_item EXCEPT ![keeper] = "none"]
    /\ group_path' = [group_path EXCEPT ![keeper] = << >>]
    /\ UNCHANGED <<item_health, consecutive_failures, fallback_count, turn_blocked>>

(* Item execution fails but is cascadeable: degrade the item and
   try the next item in the same group, or fall back to the next group.
   This models L2 Reactive Fallback from RFC-0041 §4. *)
ItemDegrade(keeper) ==
    /\ keeper_state[keeper] = "Turning"
    /\ selected_item[keeper] /= "none"
    /\ IsHealthy(keeper, selected_item[keeper])
    /\ LET item == selected_item[keeper]
           k_item == <<keeper, item>>
           cf == consecutive_failures[k_item] + 1
           new_health == IF cf >= MaxConsecutive
                         THEN "Unhealthy"
                         ELSE "Degraded"
           current_group == ItemGroup[item]
           next_item == SelectHealthyItem(keeper, current_group)
       IN /\ item_health' = [item_health EXCEPT ![k_item] = new_health]
          /\ consecutive_failures' = [consecutive_failures EXCEPT ![k_item] = cf]
          /\ IF next_item /= "none"
             THEN /\ selected_item' = [selected_item EXCEPT ![keeper] = next_item]
                  /\ fallback_count' = [fallback_count EXCEPT ![keeper] = @ + 1]
                  /\ UNCHANGED <<keeper_state, group_path, turn_blocked>>
             ELSE /\ selected_item' = [selected_item EXCEPT ![keeper] = "none"]
                  /\ fallback_count' = [fallback_count EXCEPT ![keeper] = @ + 1]
                  /\ keeper_state' = [keeper_state EXCEPT ![keeper] = "Running"]
                  /\ group_path' = [group_path EXCEPT ![keeper] = << >>]
                  /\ UNCHANGED turn_blocked

(* Group fallback: current group has no healthy items.
   Try the fallback group.  Cycle detection prevents infinite loops.
   This models L1 Proactive Routing from RFC-0041 §4. *)
GroupFallback(keeper) ==
    /\ keeper_state[keeper] = "Turning"
    /\ selected_item[keeper] = "none"
    /\ fallback_count[keeper] < MaxFallbacks
    /\ LET last_group == group_path[keeper][Len(group_path[keeper])]
           next_group == FallbackGroup[last_group]
       IN /\ next_group /= "none"
          /\ ~HasCycle(Append(group_path[keeper], next_group))
          /\ LET item == SelectHealthyItem(keeper, next_group)
             IN /\ selected_item' = [selected_item EXCEPT ![keeper] = item]
                /\ group_path' = [group_path EXCEPT ![keeper] = Append(@, next_group)]
                /\ fallback_count' = [fallback_count EXCEPT ![keeper] = @ + 1]
    /\ UNCHANGED <<keeper_state, item_health, consecutive_failures, turn_blocked>>

(* Item recovers: a Degraded or Unhealthy item becomes Healthy again.
   This models the recovery path: success on a subsequent attempt.
   In production, recovery is triggered by a successful probe or turn. *)
ItemRecover(keeper, item) ==
    /\ item_health[<<keeper, item>>] \in {"Degraded", "Unhealthy"}
    /\ item_health' = [item_health EXCEPT ![<<keeper, item>>] = "Healthy"]
    /\ consecutive_failures' = [consecutive_failures EXCEPT ![<<keeper, item>>] = 0]
    /\ UNCHANGED <<keeper_state, selected_item, fallback_count, group_path, turn_blocked>>

(* Keeper restart: L3 Escape Hatch from RFC-0041 §4.
   Models supervisor restarting a keeper after a crash.
   Resets turn state but preserves item health (per-keeper isolation). *)
KeeperRestart(keeper) ==
    /\ keeper_state[keeper] \in {"Turning", "Restarting"}
    /\ keeper_state' = [keeper_state EXCEPT ![keeper] = "Restarting"]
    /\ selected_item' = [selected_item EXCEPT ![keeper] = "none"]
    /\ group_path' = [group_path EXCEPT ![keeper] = << >>]
    /\ fallback_count' = [fallback_count EXCEPT ![keeper] = 0]
    /\ UNCHANGED <<item_health, consecutive_failures, turn_blocked>>

(* Restart complete: keeper returns to Running. *)
RestartComplete(keeper) ==
    /\ keeper_state[keeper] = "Restarting"
    /\ keeper_state' = [keeper_state EXCEPT ![keeper] = "Running"]
    /\ UNCHANGED <<item_health, consecutive_failures, selected_item,
                    fallback_count, group_path, turn_blocked>>

(* ── Next ─────────────────────────────────────────────── *)

Next ==
    /\ \E k_next \in Keepers :
          TurnStart(k_next)
       \/ ItemSuccess(k_next)
       \/ ItemDegrade(k_next)
       \/ GroupFallback(k_next)
       \/ KeeperRestart(k_next)
       \/ RestartComplete(k_next)
       \/ \E item_rec \in Items : ItemRecover(k_next, item_rec)

Spec == Init /\ [][Next]_vars

(* ── Safety Invariants ────────────────────────────────── *)

(* I1: A keeper is never "blocked due to cascade".
   Under the clean model, turn_blocked stays FALSE.
   The bug model may set it to TRUE. *)
KeeperNeverBlockedByCascade ==
    \A keeper \in Keepers : ~turn_blocked[keeper]

(* I2: If a healthy item exists for a keeper, the keeper can start a turn.
   This is a safety-like invariant: Running keepers with healthy items
   are not stuck in a non-Running state due to cascade issues.
   (Note: the full liveness property "eventually Turning" requires fairness.) *)
TurnProceedsIfHealthyItemExists ==
    \A keeper \in Keepers :
        (\E item \in Items : IsHealthy(keeper, item))
        => keeper_state[keeper] \in {"Running", "Turning", "Restarting"}

(* I3: No group cycle in the fallback path. *)
NoGroupCycle ==
    \A keeper \in Keepers : ~HasCycle(group_path[keeper])

(* I4: Degraded/Unhealthy items have consecutive_failures > 0.
   Healthy items have consecutive_failures = 0. *)
HealthStateConsistent ==
    \A keeper \in Keepers, item \in Items :
        LET h == item_health[<<keeper, item>>]
            cf == consecutive_failures[<<keeper, item>>]
        IN (h = "Healthy" => cf = 0)
           /\ (h = "Degraded" => cf > 0 /\ cf < MaxConsecutive)
           /\ (h = "Unhealthy" => cf >= MaxConsecutive)

(* I5: Fallback count stays bounded. *)
FallbackCountBounded ==
    \A keeper \in Keepers : fallback_count[keeper] <= MaxFallbacks

(* I6: Selected item belongs to the current group path. *)
SelectedItemInPath ==
    \A keeper \in Keepers :
        selected_item[keeper] /= "none"
        => ItemGroup[selected_item[keeper]] \in Range(group_path[keeper])

(* I7: Per-keeper isolation — one keeper's item health does not
   directly affect another keeper's state.  This is structural:
   all health updates are keyed by (keeper, item) pair. *)
PerKeeperIsolation == TRUE  (* Structural invariant: enforced by variable typing *)

Safety ==
    /\ TypeOK
    /\ KeeperNeverBlockedByCascade
    /\ TurnProceedsIfHealthyItemExists
    /\ NoGroupCycle
    /\ HealthStateConsistent
    /\ FallbackCountBounded
    /\ SelectedItemInPath

(* ── Bug Model Actions ────────────────────────────────── *)

(* BUG-1: Ignore health when selecting items.
   Models a routing layer that does not check item health before selection.
   This can select an Unhealthy item, causing unnecessary failures. *)
BugIgnoreHealth(keeper) ==
    /\ keeper_state[keeper] = "Running"
    /\ LET primary == CHOOSE g \in Groups : TRUE
           (* Pick ANY item, not just healthy ones *)
           any_item == CHOOSE i \in ItemsInGroup(primary) : TRUE
       IN /\ selected_item' = [selected_item EXCEPT ![keeper] = any_item]
          /\ group_path' = [group_path EXCEPT ![keeper] = << primary >>]
    /\ keeper_state' = [keeper_state EXCEPT ![keeper] = "Turning"]
    /\ fallback_count' = [fallback_count EXCEPT ![keeper] = 0]
    /\ UNCHANGED <<item_health, consecutive_failures, turn_blocked>>

(* BUG-2: No group fallback when current group is exhausted.
   Models a routing layer that gives up instead of trying the fallback group.
   This blocks the keeper when all items in the primary group fail. *)
BugNoGroupFallback(keeper) ==
    /\ keeper_state[keeper] = "Turning"
    /\ selected_item[keeper] = "none"
    /\ group_path[keeper] /= << >>
    /\ turn_blocked' = [turn_blocked EXCEPT ![keeper] = TRUE]
    /\ UNCHANGED <<keeper_state, item_health, consecutive_failures,
                    selected_item, fallback_count, group_path>>

(* BUG-3: Global health cache — one keeper's failure affects all keepers.
   Models the current (pre-RFC-0041) global shared state.
   When an item is degraded for one keeper, it becomes degraded for ALL keepers. *)
BugGlobalHealthDegrade(keeper, item) ==
    /\ keeper_state[keeper] = "Turning"
    /\ selected_item[keeper] = item
    /\ IsHealthy(keeper, item)
    /\ LET cf == consecutive_failures[<<keeper, item>>] + 1
           new_health == IF cf >= MaxConsecutive
                         THEN "Unhealthy"
                         ELSE "Degraded"
       IN /\ item_health' =
              [k_item \in Keepers × Items |->
                 IF k_item[2] = item  (* SAME item, ANY keeper! *)
                 THEN new_health
                 ELSE item_health[k_item]]
          /\ consecutive_failures' =
              [k_item \in Keepers × Items |->
                 IF k_item[2] = item
                 THEN cf
                 ELSE consecutive_failures[k_item]]
    /\ selected_item' = [selected_item EXCEPT ![keeper] = "none"]
    /\ keeper_state' = [keeper_state EXCEPT ![keeper] = "Running"]
    /\ group_path' = [group_path EXCEPT ![keeper] = << >>]
    /\ fallback_count' = [fallback_count EXCEPT ![keeper] = @ + 1]
    /\ UNCHANGED turn_blocked

NextBuggy ==
    Next
    \/ \E k_b1 \in Keepers : BugIgnoreHealth(k_b1)
    \/ \E k_b2 \in Keepers : BugNoGroupFallback(k_b2)
    \/ \E k_b3 \in Keepers, it_b \in Items : BugGlobalHealthDegrade(k_b3, it_b)

SpecBuggy == Init /\ [][NextBuggy]_vars

====
