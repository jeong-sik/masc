type item =
  | Held_without_actor of
      { task_id : string
      ; title : string
      ; assignee : string
      ; since : string
      }
  | Producer_record_unreadable of
      { task_id : string
      ; title : string
      ; producer : string
      ; since : string
      ; detail : string
      }

let task_id = function
  | Held_without_actor { task_id; _ }
  | Producer_record_unreadable { task_id; _ } -> task_id
;;

let title = function
  | Held_without_actor { title; _ }
  | Producer_record_unreadable { title; _ } -> title
;;

let waiting_since = function
  | Held_without_actor { since; _ } | Producer_record_unreadable { since; _ } -> since
;;

let task_label ~task_id ~title =
  let title = String.trim title in
  if String.equal title ""
  then task_id
  else Printf.sprintf "%s · %s" task_id title
;;

let summary = function
  | Held_without_actor { task_id; title; assignee; _ } ->
    Printf.sprintf
      "%s: held by %s, which has no Keeper queue"
      (task_label ~task_id ~title)
      assignee
  | Producer_record_unreadable { task_id; title; producer; detail; _ } ->
    Printf.sprintf
      "%s: the Keeper record for %s does not decode — %s"
      (task_label ~task_id ~title)
      producer
      detail
;;

let next_step = function
  | Held_without_actor _ -> "masc_operator_task_recovery_resolve"
  | Producer_record_unreadable _ -> "repair the Keeper record, then this resolves itself"
;;

(* The route is resolved through the same computation the rejection delivery
   uses, so a name this list calls actorless is exactly a name a verdict cannot
   be delivered to. Asking a second way — comparing against the live registry
   alone, say — would let the list and the delivery disagree about the same
   agent, and the disagreement would show as a Task that the list says is fine
   and delivery says is unreachable. *)
let classify_held ~config ~task_id ~title ~assignee ~since =
  match Keeper_producer_route.resolve ~config assignee with
  | Ok (Keeper_producer_route.Keeper _) -> None
  | Ok Keeper_producer_route.No_keeper ->
    Some (Held_without_actor { task_id; title; assignee; since })
  | Error detail ->
    Some (Producer_record_unreadable { task_id; title; producer = assignee; since; detail })
;;

let project ~(config : Workspace_utils_backend_setup.config) tasks =
  List.filter_map
    (fun (task : Masc_domain.task) ->
       match task.task_status with
       (* A completion waits on the system authority, which is running. It is
          not the operator's row. *)
       | Masc_domain.AwaitingVerification _ -> None
       | Masc_domain.Claimed { assignee; claimed_at = since } ->
         classify_held ~config ~task_id:task.id ~title:task.title ~assignee ~since
       | Masc_domain.InProgress { assignee; started_at = since } ->
         classify_held ~config ~task_id:task.id ~title:task.title ~assignee ~since
       | Masc_domain.Todo | Masc_domain.Done _ | Masc_domain.Cancelled _ -> None)
    tasks
  (* Oldest first: the longest wait is the row that has gone unanswered the
     longest, and a surface that shows only a few shows those. [stable_sort]
     so two rows stamped the same second keep backlog order rather than
     swapping between reads. *)
  |> List.stable_sort (fun left right ->
    String.compare (waiting_since left) (waiting_since right))
;;
