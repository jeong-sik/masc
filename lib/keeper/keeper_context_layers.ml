(** See [keeper_context_layers.mli] for the contract. *)

type layer_id =
  | Active_goals
  | Current_task
  | Connected_surfaces
  | Namespace_state
  | Autonomous_trigger
  | Scheduled_automation
  | Pending_mentions
  | Scope_messages
  | Claimable_work
  | Board_activity

(* Prefix-cache ordering: emit larger, more stable sections first so providers
   can reuse a longer shared prefix across cycles; highly volatile reactive
   signals stay later in the same user message. [Current_task] sits directly
   after [Active_goals]: the claimed task is standing context that changes on
   claim/release, not per cycle. *)
let ordered =
  [ Active_goals
  ; Current_task
  ; Connected_surfaces
  ; Namespace_state
  ; Autonomous_trigger
  ; Scheduled_automation
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
  | Connected_surfaces -> 2
  | Namespace_state -> 3
  | Autonomous_trigger -> 4
  | Scheduled_automation -> 5
  | Pending_mentions -> 6
  | Scope_messages -> 7
  | Claimable_work -> 8
  | Board_activity -> 9
;;

let assemble ~content_of =
  ordered |> List.filter_map content_of |> String.concat ""
;;
