(* See candle_snapshot.mli. *)

open Result.Syntax

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
  let* linked_task_ids = Candle_tasks.linked_task_ids config ~goal_id:goal.Goal_store.id in
  let* at = Candle_stamp.at ~now in
  let* row = event ~at ~linked_task_ids goal verdict in
  Result.map_error
    (Candle_ledger.update_error_to_string Fun.id)
    (Candle_ledger.update ~base_path:config.base_path (fun (_ : Candle_ledger.view) ->
       Ok ([ row ], ())))
;;

let record ~now (config : Workspace_utils_backend_setup.config) goal verdict =
  let refused detail =
    "candle snapshot: " ^ detail
    ^ "; repair the reported problem, then retry the same verification request"
  in
  match Candle_status.for_recording ~base_path:config.base_path with
  | Candle_status.Recording_off -> Ok ()
  | Candle_status.Recording_disabled { reason } ->
    Error (refused ("configuration unavailable: " ^ reason))
  | Candle_status.Recording_unavailable { reason } ->
    Error (refused ("ledger recovery unavailable: " ^ reason))
  | Candle_status.Recording_enabled _ ->
    Result.map_error
      refused
      (write ~now config goal verdict)
;;

let before_proof_commit config goal verdict =
  record ~now:Time_compat.now config goal verdict
;;
