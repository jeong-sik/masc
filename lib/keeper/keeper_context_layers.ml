(** See [keeper_context_layers.mli] for the contract. *)

type layer_id =
  | Active_goals
  | Connected_surfaces
  | Namespace_state
  | Context_health
  | Autonomous_trigger
  | Continuity
  | Pending_mentions
  | Scope_messages
  | Claimable_work
  | Board_activity

(* Prefix-cache ordering: emit larger, more stable sections first so providers
   can reuse a longer shared prefix across cycles; highly volatile reactive
   signals stay later in the same user message. *)
let ordered =
  [ Active_goals
  ; Connected_surfaces
  ; Namespace_state
  ; Context_health
  ; Autonomous_trigger
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
  | Connected_surfaces -> 1
  | Namespace_state -> 2
  | Context_health -> 3
  | Autonomous_trigger -> 4
  | Continuity -> 5
  | Pending_mentions -> 6
  | Scope_messages -> 7
  | Claimable_work -> 8
  | Board_activity -> 9
;;

let assemble ~content_of =
  ordered |> List.filter_map content_of |> String.concat ""
;;
