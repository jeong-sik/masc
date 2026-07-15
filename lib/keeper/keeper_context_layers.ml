(** See [keeper_context_layers.mli] for the contract. *)

type layer_id =
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
   signals stay later in the same user message. [Current_task] is standing
   context that changes on claim/release, not per cycle. *)
let ordered =
  [ Current_task
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
  | Current_task -> 0
  | Connected_surfaces -> 1
  | Namespace_state -> 2
  | Autonomous_trigger -> 3
  | Scheduled_automation -> 4
  | Pending_mentions -> 5
  | Scope_messages -> 6
  | Claimable_work -> 7
  | Board_activity -> 8
;;

let assemble ~content_of =
  ordered |> List.filter_map content_of |> String.concat ""
;;
