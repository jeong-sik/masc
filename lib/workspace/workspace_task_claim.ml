(** Workspace_task_claim — claim_task_r and claim helpers.

    Extracted from Workspace_task to separate claim logic from classification,
    creation, and transitions.  All bindings are re-exported by [Workspace_task]
    via [include Workspace_task_claim]. *)

open Masc_domain
open! Workspace_utils
open! Workspace_state
open! Workspace_broadcast
open Workspace_backlog

let active_owned_task_ids_for_agent config ~agent_name (backlog : Masc_domain.backlog)
  =
  backlog.tasks
  |> List.filter_map (fun (task : Masc_domain.task) ->
         match task.task_status with
         | Claimed { assignee; _ } | InProgress { assignee; _ }
           when Workspace_task_classify.same_task_actor config assignee agent_name ->
           Some task.id
         | Todo
         | Claimed _
         | InProgress _
         | AwaitingVerification _
         | Done _
         | Cancelled _ -> None)
  |> List.sort_uniq String.compare
;;

let run_post_commit ~task_id ~agent_name ~action label f =
  try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.TaskState.error
      "task %s committed but post-commit projection failed task_id=%s agent=%s label=%s detail=%s"
      action task_id agent_name label (Printexc.to_string exn)
;;

let emit_auto_start_side_effects config ~agent_name ~task_id ~from_status ~to_status =
  let run label f = run_post_commit ~task_id ~agent_name ~action:"start" label f in
  run "broadcast" (fun () ->
    let _ =
      broadcast
        ~audience:System_record
        config
        ~from_agent:agent_name
        ~content:(Printf.sprintf "Started %s" task_id)
    in
    ());
  run "activity" (fun () ->
    Workspace_task_classify.emit_task_activity
      config
      ~agent_name
      ~task_id
      ~kind:(Event_kind.Task.to_string Event_kind.Task.Started)
      ~payload:(`Assoc [ "task_id", `String task_id ]));
  run "observe_transition" (fun () ->
    Workspace_task_classify.observe_task_transition
      config
      ~agent_name
      ~task_id
      ~transition:Masc_domain.Start
      ~details:
        (Workspace_task_classify.task_transition_details
           ~from_status
           ~to_status
           ()));
  run "push_task_event" (fun () ->
    (Atomic.get Workspace_hooks.push_task_event_fn)
      ~event_type:"masc/task_transition"
      ~details:
        [ "task_id", `String task_id
        ; "action", `String "start"
        ; "agent_name", `String agent_name
        ]);
  run "transition_log" (fun () ->
    log_event
      config
      (Workspace_task_classify.transition_log_event
         ~agent_name
         ~task_id
         ~from_status
         ~to_status
         ~action:(Masc_domain.task_action_to_string Masc_domain.Start)
         ~assignee:agent_name
         ()))
;;

(** Claim [task_id] for [agent_name]. *)
let claim_task_with_details_r
      config
      ~agent_name
      ~task_id
      ?(auto_start = false)
      ()
  : (Masc_domain.task * string) Masc_domain.masc_result
  =
  let open Result.Syntax in
  let* () = if not (is_initialized config) then Error (Masc_domain.System Masc_domain.System_error.NotInitialized) else Ok () in
  let* () =
    match validate_agent_name_r agent_name, validate_task_id_r task_id with
    | Error e, _ -> Error e
    | _, Error e -> Error e
    | Ok _, Ok _ -> Ok ()
  in
  let lock_path = backlog_lock_path config in
  with_file_lock config lock_path (fun () ->
    match read_prepared_backlog_r config with
    | Error msg -> Error (Masc_domain.System (Masc_domain.System_error.IoError msg))
    | Ok prepared ->
      let backlog = prepared.backlog in
      (try
         let* () =
           match Task_id_map.find_opt task_id prepared.tasks_by_id with
           | None -> Error (Masc_domain.Task (Masc_domain.Task_error.NotFound task_id))
           | Some _ -> Ok ()
         in
         let duplicate_count =
           List.fold_left
             (fun count (t : task) ->
                if String.equal t.id task_id then count + 1 else count)
             0
             backlog.tasks
         in
         let* () =
           if duplicate_count > 1
           then
             Error
               (Masc_domain.Task
                  (Masc_domain.Task_error.InvalidState
                     (Printf.sprintf
                        "Backlog contains %d duplicate rows for task %s; refusing ambiguous claim."
                        duplicate_count
                        task_id)))
           else Ok ()
         in
         let now = now_iso () in
         (* fold_left to find+transform in a single pass without mutable refs.
            Uses polymorphic variants for inline state tracking. *)
         let claim_state, new_tasks =
           List.fold_left
             (fun (state, acc) (t : task) ->
                if t.id = task_id
                then (
                  (* One claim decision is shared with the auto-claim path
                     ([claim_next_r]). [resolve_claim] owns the self-check
                     (normalized via [same_task_actor]) and rejects every
                     [AwaitingVerification] obligation as pending a completion
                     authority's verdict. *)
                  match
                    Workspace_task_lifecycle.resolve_claim
                      ~same_actor:(fun a ->
                        Workspace_task_classify.same_task_actor config a agent_name)
                      ~agent_name
                      ~now
                      t
                  with
                  | Workspace_task_lifecycle.Worker_claim claimed_status ->
                    let final_status =
                      if auto_start
                      then Masc_domain.InProgress { assignee = agent_name; started_at = now }
                      else claimed_status
                    in
                    let updated_task = { t with task_status = final_status } in
                    `Claimed_ok (updated_task, claimed_status), updated_task :: acc
                  | Workspace_task_lifecycle.Held_pending_verdict { verification_id } ->
                    `Pending_verdict verification_id, t :: acc
                  | Workspace_task_lifecycle.Self_owned ->
                    if auto_start
                    then (
                      match t.task_status with
                      | Masc_domain.Claimed _ as from_status ->
                        let to_status =
                          Masc_domain.InProgress { assignee = agent_name; started_at = now }
                        in
                        let updated_task = { t with task_status = to_status } in
                        `Already_mine_started (updated_task, from_status, to_status),
                        updated_task :: acc
                      | Masc_domain.InProgress _
                      | Masc_domain.Todo
                      | Masc_domain.AwaitingVerification _
                      | Masc_domain.Done _
                      | Masc_domain.Cancelled _ ->
                        `Already_mine t, t :: acc)
                    else `Already_mine t, t :: acc
                  | Workspace_task_lifecycle.Held_by_other holder ->
                    `Claimed_by holder, t :: acc
                  | Workspace_task_lifecycle.Held_terminal status ->
                    `Terminal status, t :: acc)
                else state, t :: acc)
             (`Not_found, [])
             backlog.tasks
         in
         let new_tasks = List.rev new_tasks in
         let run_claim_post_commit label f =
           run_post_commit ~task_id ~agent_name ~action:"claim" label f
         in
         match claim_state with
         | `Not_found -> Error (Masc_domain.Task (Masc_domain.Task_error.NotFound task_id))
         | `Terminal status ->
           (* RFC-0323: completed work is terminal — point the caller at the
              linked re-run path instead of a bare AlreadyClaimed. *)
           Error
             (Masc_domain.Task
                (Masc_domain.Task_error.InvalidState
                   (Printf.sprintf
                      "Task %s is %s — completed work is terminal. To run it \
                       again, create a new task with predecessor_task_id=%s \
                       (masc_add_task, RFC-0323)."
                      task_id
                      (Masc_domain.task_status_to_string status)
                      task_id)))
         | `Claimed_by other -> Error (Masc_domain.Task (Masc_domain.Task_error.AlreadyClaimed { task_id; by = other }))
         | `Pending_verdict verification_id ->
           Error
             (Masc_domain.Task
                (Masc_domain.Task_error.InvalidState
                   (Printf.sprintf
                      "Task %s awaits a completion authority's verdict \
                       (verification_id=%s) and is not claimable by any agent. A \
                       Keeper is not a verifier."
                      task_id
                      verification_id)))
         | `Already_mine existing_task ->
           (* When [existing_task] is already [InProgress] (or [auto_start = false]),
              no [Claimed -> InProgress] transition occurred: report the existing
              claim without claiming an auto-start happened. *)
           let msg = Printf.sprintf "Task %s is already claimed by you" task_id in
           Ok (existing_task, msg)
         | `Already_mine_started (started_task, from_status, to_status) ->
           let new_backlog = { backlog with tasks = new_tasks } in
           write_backlog
             ~after_commit:(fun () ->
               Task_cache_invariant.clear_stale_agent_task config
                 ~cause:Task_cache_invariant.After_commit
                 ~agent_name ~task_id ~status:started_task.task_status
                 ~module_name:"claim_task_r.already_mine_auto_start")
             config new_backlog;
           run_claim_post_commit "agent_state" (fun () ->
             Workspace_task_classify.update_local_agent_state config ~agent_name (fun agent ->
               { agent with status = Busy; current_task = Some task_id }));
           emit_auto_start_side_effects config ~agent_name ~task_id ~from_status ~to_status;
           let msg =
             Printf.sprintf
               "Task %s is already claimed by you. Task auto-started — begin work now."
               task_id
           in
           Ok (started_task, msg)
         | `Claimed_ok (claimed_task, claimed_status) ->
           (* [write_backlog] stamps version/last_updated at the commit point. *)
           let new_backlog = { backlog with tasks = new_tasks } in
           write_backlog
             ~after_commit:(fun () ->
               Task_cache_invariant.clear_stale_agent_task config
                 ~cause:Task_cache_invariant.After_commit
                 ~agent_name ~task_id ~status:claimed_task.task_status
                 ~module_name:"claim_task_r.claimed_ok")
             config new_backlog;
           run_claim_post_commit "agent_state" (fun () ->
             Workspace_task_classify.update_local_agent_state config ~agent_name (fun agent ->
               { agent with status = Busy; current_task = Some task_id }));
           run_claim_post_commit "broadcast" (fun () ->
             let _ =
               broadcast ~audience:System_record
                 config
                 ~from_agent:agent_name
                 ~content:(Printf.sprintf "Claimed %s" task_id)
             in
             ());
           run_claim_post_commit "activity" (fun () ->
             Workspace_task_classify.emit_task_activity
               config
               ~agent_name
               ~task_id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Claimed)
               ~payload:(`Assoc [ "task_id", `String task_id ]));
           run_claim_post_commit "claim_log" (fun () ->
             log_event
               config
               (`Assoc
                      [ "type", `String "task_claim"
                      ; "agent", `String agent_name
                      ; ( "actor_kind"
                        , `String
                            (Workspace_task_classify.task_actor_kind_to_string
                               Workspace_task_classify.Agent) )
                      ; "task", `String task_id
                      ; "ts", `String now
                      ]));
           run_claim_post_commit "observe_transition" (fun () ->
             Workspace_task_classify.observe_task_transition
               config
               ~agent_name
               ~task_id
               ~transition:Masc_domain.Claim
               ~details:
                 (Workspace_task_classify.task_transition_details
                    ~from_status:Masc_domain.Todo
                    ~to_status:claimed_status
                    ()));
           if auto_start
           then
             emit_auto_start_side_effects
               config
               ~agent_name
               ~task_id
               ~from_status:claimed_status
               ~to_status:claimed_task.task_status;
           let base_msg = Printf.sprintf "%s claimed %s" agent_name task_id in
           let claim_msg =
             if auto_start
             then base_msg ^ " Task auto-started — begin work now."
             else base_msg
           in
           Ok (claimed_task, claim_msg)
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | e -> Error (Masc_domain.System (Masc_domain.System_error.IoError (Printexc.to_string e)))))
;;

let claim_task_r config ~agent_name ~task_id ?(auto_start = false) ()
  : string Masc_domain.masc_result
  =
  Result.map snd (claim_task_with_details_r config ~agent_name ~task_id ~auto_start ())
;;
