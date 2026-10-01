(* See candle_snapshot.mli. *)

let ( let* ) = Result.bind

(* The link registry is read from its primary file only. A registry that cannot
   be read, or whose primary file is gone while a recovery copy remains, refuses
   the step: linked Tasks are what the payout is shared among. The registry
   lists only Goals that have links, so a Goal missing from it has none. *)
let linked_task_ids config ~goal_id =
  match Workspace_goal_index.read_goal_task_links_authoritative_r config with
  | Error detail ->
    Error (Printf.sprintf "the goal-task links could not be read: %s" detail)
  | Ok links ->
    (match List.assoc_opt goal_id links with
     | Some task_ids -> Ok task_ids
     | None -> Ok [])
;;

let event ~at ~linked_task_ids (goal : Goal_store.goal) (verdict : Goal_verification.verdict)
  =
  let* passed_at = Candle_stamp.copied ~what:"the verdict's recorded_at" verdict.recorded_at in
  let* goal_created_at = Candle_stamp.copied ~what:"the goal's created_at" goal.created_at in
  Ok
    { Candle_event.at
    ; body =
        Candle_event.Snapshot
          { goal_id = goal.id
          ; request_id = verdict.request_id
          ; verification_run_id = verdict.verification_run_id
          ; criterion_revision = goal.criterion_revision
          ; passed_at
          ; goal_created_at
          ; due_date = goal.due_date
          ; title = goal.title
          ; metric = goal.metric
          ; target_value = goal.target_value
          ; linked_task_ids
          }
    }
;;

let write ~now (config : Workspace_utils_backend_setup.config) goal verdict =
  let* linked_task_ids = linked_task_ids config ~goal_id:goal.Goal_store.id in
  let* at = Candle_stamp.at ~now in
  let* row = event ~at ~linked_task_ids goal verdict in
  Result.map_error
    (Candle_ledger.update_error_to_string Fun.id)
    (Candle_ledger.update ~base_path:config.base_path (fun (_ : Candle_ledger.view) ->
       Ok ([ row ], ())))
;;

let record ~now (config : Workspace_utils_backend_setup.config) goal verdict =
  match Candle_status.current ~base_path:config.base_path with
  | Candle_config.Off -> Ok ()
  | Candle_config.Disabled { reason } ->
    Log.Misc.warn
      "candle: no snapshot for goal_id=%s because candle is disabled: %s"
      goal.Goal_store.id
      reason;
    Ok ()
  | Candle_config.Enabled _ ->
    Result.map_error
      (fun detail -> "candle snapshot: " ^ detail)
      (write ~now config goal verdict)
;;

let before_proof_commit config goal verdict =
  record ~now:Time_compat.now config goal verdict
;;
