type item =
  | Cancel_claim of
      { task_id : string
      ; assignee : string
      ; submitted_at : string
      ; reason : Workspace_verification_store.cancellation_reason_read
      }
  | Held_without_actor of
      { task_id : string
      ; assignee : string
      ; since : string
      }
  | Producer_record_unreadable of
      { task_id : string
      ; producer : string
      ; since : string
      ; detail : string
      }

let task_id = function
  | Cancel_claim { task_id; _ }
  | Held_without_actor { task_id; _ }
  | Producer_record_unreadable { task_id; _ } -> task_id
;;

let waiting_since = function
  | Cancel_claim { submitted_at; _ } -> submitted_at
  | Held_without_actor { since; _ } | Producer_record_unreadable { since; _ } -> since
;;

let summary = function
  | Cancel_claim { task_id; assignee; reason; _ } ->
    let stated =
      match reason with
      | Workspace_verification_store.Cancellation_reason_stated reason -> reason
      | Workspace_verification_store.Cancellation_reason_unreadable detail ->
        "reason unreadable: " ^ detail
    in
    Printf.sprintf "%s: %s gave up — %s" task_id assignee stated
  | Held_without_actor { task_id; assignee; _ } ->
    Printf.sprintf "%s: held by %s, which has no Keeper queue" task_id assignee
  | Producer_record_unreadable { task_id; producer; detail; _ } ->
    Printf.sprintf "%s: the Keeper record for %s does not decode — %s" task_id producer detail
;;

let next_step = function
  | Cancel_claim _ -> "grant or refuse the stop in the verify queue"
  | Held_without_actor _ -> "masc_operator_task_recovery_resolve"
  | Producer_record_unreadable _ -> "repair the Keeper record, then this resolves itself"
;;

(* The route is resolved through the same computation the rejection delivery
   uses, so a name this list calls actorless is exactly a name a verdict cannot
   be delivered to. Asking a second way — comparing against the live registry
   alone, say — would let the list and the delivery disagree about the same
   agent, and the disagreement would show as a Task that the list says is fine
   and delivery says is unreachable. *)
let classify_held ~config ~task_id ~assignee ~since =
  match Keeper_producer_route.resolve ~config assignee with
  | Ok (Keeper_producer_route.Keeper _) -> None
  | Ok Keeper_producer_route.No_keeper ->
    Some (Held_without_actor { task_id; assignee; since })
  | Error detail ->
    Some (Producer_record_unreadable { task_id; producer = assignee; since; detail })
;;

let project ~(config : Workspace_utils_backend_setup.config) tasks =
  List.filter_map
    (fun (task : Masc_domain.task) ->
       match task.task_status with
       | Masc_domain.AwaitingVerification
           { assignee; submitted_at; intent = Masc_domain.Cancel_task; verification_id; _ }
         ->
         Some
           (Cancel_claim
              { task_id = task.id
              ; assignee
              ; submitted_at
              ; reason =
                  Workspace_verification_store.read_cancellation_reason
                    ~base_path:config.Workspace.base_path
                    ~verification_id
              })
       (* A completion waits on the system authority, which is running: today's
          verdicts and rejection deliveries both moved. It is not the
          operator's row. *)
       | Masc_domain.AwaitingVerification { intent = Masc_domain.Complete_task; _ } -> None
       | Masc_domain.Claimed { assignee; claimed_at = since } ->
         classify_held ~config ~task_id:task.id ~assignee ~since
       | Masc_domain.InProgress { assignee; started_at = since } ->
         classify_held ~config ~task_id:task.id ~assignee ~since
       | Masc_domain.Todo | Masc_domain.Done _ | Masc_domain.Cancelled _ -> None)
    tasks
  (* Oldest first: the longest wait is the row that has gone unanswered the
     longest, and a surface that shows only a few shows those. [stable_sort]
     so two rows stamped the same second keep backlog order rather than
     swapping between reads. *)
  |> List.stable_sort (fun left right ->
    String.compare (waiting_since left) (waiting_since right))
;;
