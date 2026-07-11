type release_failure =
  { task_id : Keeper_id.Task_id.t
  ; error : Masc_domain.masc_error
  }

type error =
  | Discovery_failed of string
  | Release_failed of
      { released : Keeper_id.Task_id.t list
      ; failures : release_failure list
      }

let release_owned_active_tasks ~config ~meta ~actor ~reason_tag ~handoff_context =
  match Keeper_current_task_reconcile.owned_active_tasks_for_meta ~config ~meta with
  | Error detail -> Error (Discovery_failed detail)
  | Ok owned_tasks ->
    let released, failures =
      List.fold_left
        (fun (released, failures)
             (owned : Keeper_current_task_reconcile.owned_active_task) ->
           let task_id = Keeper_id.Task_id.to_string owned.task_id in
           match
             Workspace.force_release_task_r
               config
               ~agent_name:actor
               ~task_id
               ~handoff_context
               ()
           with
           | Ok detail ->
             Log.Keeper.warn
               "%s: released active task %s during %s: %s"
               meta.name
               task_id
               reason_tag
               detail;
             owned.task_id :: released, failures
           | Error error ->
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string ReconcileFailures)
               ~labels:[ "keeper", meta.name; "phase", reason_tag ]
               ();
             released, { task_id = owned.task_id; error } :: failures)
        ([], [])
        owned_tasks
    in
    (match List.rev failures with
     | [] -> Ok (List.rev released)
     | failures ->
       Error
         (Release_failed
            { released = List.rev released
            ; failures
            }))
;;

let error_to_string = function
  | Discovery_failed detail -> "owned-task discovery failed: " ^ detail
  | Release_failed { failures; _ } ->
    failures
    |> List.map (fun failure ->
      Printf.sprintf
        "%s: %s"
        (Keeper_id.Task_id.to_string failure.task_id)
        (Masc_domain.masc_error_to_string failure.error))
    |> String.concat "; "
    |> Printf.sprintf "owned-task release failed: %s"
;;
