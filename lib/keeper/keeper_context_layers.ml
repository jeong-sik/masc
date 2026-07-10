(** See [keeper_context_layers.mli] for the contract. *)

type layer_id =
  | Active_goals
  | Current_task
  | Working_state
  | Connected_surfaces
  | Namespace_state
  | Context_health
  | Autonomous_trigger
  | Scheduled_automation
  | Continuity
  | Pending_mentions
  | Scope_messages
  | Claimable_work
  | Board_activity

(* Prefix-cache ordering: emit larger, more stable sections first so providers
   can reuse a longer shared prefix across cycles; highly volatile reactive
   signals stay later in the same user message. [Current_task] sits directly
   after [Active_goals]: the claimed task is standing context that changes on
   claim/release, not per cycle. [Working_state] (unresolved open loops from
   the keeper's own prior [STATE] blocks) follows for the same reason. *)
let ordered =
  [ Active_goals
  ; Current_task
  ; Working_state
  ; Connected_surfaces
  ; Namespace_state
  ; Context_health
  ; Autonomous_trigger
  ; Scheduled_automation
  ; Continuity
  ; Pending_mentions
  ; Scope_messages
  ; Claimable_work
  ; Board_activity
  ]
;;

(* Exhaustive over [layer_id]: adding a variant breaks this match at compile
   time, forcing both a position here and (via the [content_of] match at the
   call site) a rendering for the new layer. *)
let order_index = function
  | Active_goals -> 0
  | Current_task -> 1
  | Working_state -> 2
  | Connected_surfaces -> 3
  | Namespace_state -> 4
  | Context_health -> 5
  | Autonomous_trigger -> 6
  | Scheduled_automation -> 7
  | Continuity -> 8
  | Pending_mentions -> 9
  | Scope_messages -> 10
  | Claimable_work -> 11
  | Board_activity -> 12
;;

let assemble ~content_of =
  ordered |> List.filter_map content_of |> String.concat ""
;;
