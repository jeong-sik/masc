type item =
  | Held_without_keeper_route of
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
  | Awaiting_verdict of
      { task_id : string
      ; title : string
      ; producer : string
      ; since : string
      }

let task_id = function
  | Held_without_keeper_route { task_id; _ }
  | Producer_record_unreadable { task_id; _ }
  | Awaiting_verdict { task_id; _ } -> task_id
;;

let title = function
  | Held_without_keeper_route { title; _ }
  | Producer_record_unreadable { title; _ }
  | Awaiting_verdict { title; _ } -> title
;;

let waiting_since = function
  | Held_without_keeper_route { since; _ }
  | Producer_record_unreadable { since; _ }
  | Awaiting_verdict { since; _ } -> since
;;

let task_label ~task_id ~title =
  let title = String.trim title in
  if String.equal title ""
  then task_id
  else Printf.sprintf "%s · %s" task_id title
;;

let summary = function
  | Held_without_keeper_route { task_id; title; assignee; _ } ->
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
  | Awaiting_verdict { task_id; title; producer; _ } ->
    Printf.sprintf
      "%s: submitted as complete by %s, awaiting a verdict"
      (task_label ~task_id ~title)
      producer
;;

let next_step = function
  | Held_without_keeper_route _ -> "inspect the task owner before choosing recovery"
  | Producer_record_unreadable _ -> "repair the Keeper record, then this resolves itself"
  | Awaiting_verdict _ -> "read the verification request; decide it if the review does not"
;;

(* Rejection delivery uses the same route. A missing Keeper queue means that
   delivery cannot reach this name; it does not prove that a session holding
   the Task has stopped or that an operator decision was requested. *)
let classify_held ~config ~task_id ~title ~assignee ~since =
  match Keeper_producer_route.resolve ~config assignee with
  | Ok (Keeper_producer_route.Keeper _) -> None
  | Ok Keeper_producer_route.No_keeper ->
    Some (Held_without_keeper_route { task_id; title; assignee; since })
  | Error detail ->
    Some (Producer_record_unreadable { task_id; title; producer = assignee; since; detail })
;;

let project ~(config : Workspace_utils_backend_setup.config) tasks =
  List.filter_map
    (fun (task : Masc_domain.task) ->
       match task.task_status with
       (* Every submission awaiting a verdict is a row. The backlog is the
          source because the run registry keeps only its latest completed
          rows, and a review that stopped drops out of it. Nothing here
          grades which review stopped: the row carries when the submission
          was made, and the surfaces order by it. *)
       | Masc_domain.AwaitingVerification
           { assignee; submitted_at; verification_id = _; started_at = _ } ->
         Some
           (Awaiting_verdict
              { task_id = task.id
              ; title = task.title
              ; producer = assignee
              ; since = submitted_at
              })
       | Masc_domain.Claimed { assignee; claimed_at = since } ->
         classify_held ~config ~task_id:task.id ~title:task.title ~assignee ~since
       | Masc_domain.InProgress { assignee; started_at = since } ->
         classify_held ~config ~task_id:task.id ~title:task.title ~assignee ~since
       | Masc_domain.Todo | Masc_domain.Done _ | Masc_domain.Cancelled _ -> None)
    tasks
  (* Keep the oldest waits first, with stable order for equal timestamps. *)
  |> List.stable_sort (fun left right ->
    String.compare (waiting_since left) (waiting_since right))
;;
