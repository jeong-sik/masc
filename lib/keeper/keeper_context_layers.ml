(** See [keeper_context_layers.mli] for the contract. *)

type layer_id =
  | Active_goals
  | Current_task
  | Approval_authority
  | Connected_surfaces
  | Namespace_state
  | Workspace_memory
  | Lane_updates
  | Repository_freshness
  | Autonomous_trigger
  | Scheduled_automation
  | Completion_authority
  | Task_cancellations
  | Pending_mentions
  | Scope_messages
  | Own_board_posts
  | Board_activity
  | Own_recent_actions
  | Fleet_messages

(* Prefix-cache ordering: emit larger, more stable sections first so providers
   can reuse a longer shared prefix across cycles; highly volatile reactive
   signals stay later in the same user message. [Current_task] sits directly
   after [Active_goals]: the claimed task is standing context that changes on
   claim/release, not per cycle. [Own_board_posts] changes only when the
   keeper itself publishes, so it sits just ahead of the per-cycle reactive
   [Board_activity]. [Own_recent_actions] is a window that slides every turn,
   so it cannot hold a stable prefix and sits behind the sections that can.
   [Fleet_messages] carries any keeper's broadcast, so it is the most
   fleet-volatile section and sits last. *)
let ordered =
  [ Active_goals
  ; Current_task
  ; Approval_authority
  ; Connected_surfaces
  ; Namespace_state
  ; Workspace_memory
  ; Lane_updates
  ; Repository_freshness
  ; Autonomous_trigger
  ; Scheduled_automation
  ; Completion_authority
  ; Task_cancellations
  ; Pending_mentions
  ; Scope_messages
  ; Own_board_posts
  ; Board_activity
  ; Own_recent_actions
  ; Fleet_messages
  ]
;;

(* Exhaustive over [layer_id]: adding a variant breaks this match at compile
   time, forcing both a position here and (via the [content_of] match at the
   call site) a rendering for the new layer. *)
let order_index = function
  | Active_goals -> 0
  | Current_task -> 1
  | Approval_authority -> 2
  | Connected_surfaces -> 3
  | Namespace_state -> 4
  | Workspace_memory -> 5
  | Lane_updates -> 6
  | Repository_freshness -> 7
  | Autonomous_trigger -> 8
  | Scheduled_automation -> 9
  | Completion_authority -> 10
  | Task_cancellations -> 11
  | Pending_mentions -> 12
  | Scope_messages -> 13
  | Own_board_posts -> 14
  | Board_activity -> 15
  | Own_recent_actions -> 16
  | Fleet_messages -> 17
;;

let assemble ~content_of = ordered |> List.filter_map content_of |> String.concat ""
