(** Workspace_task_schedule — Scheduling: claim_next.

    Extracted from Workspace_task to separate scheduling logic (priority queue,
    existing-claim preservation) from task CRUD and state
    transitions. *)

open Masc_domain
open! Workspace_utils
open! Workspace_state
open Workspace_backlog

(** #10421: stable lowercase string label for a [task_status] suitable
    for embedding in JSONL diagnostic events.  Mirrors what the
    [task_transition] from/to fields already use so dashboards can
    join claim-loop diagnostics on identical vocabulary.  Pure; exposed for
    tests. *)
let task_status_label (status : Masc_domain.task_status) : string =
  match status with
  | Todo -> "todo"
  | Claimed _ -> "claimed"
  | InProgress _ -> "in_progress"
  | AwaitingVerification _ -> "awaiting_verification"
  | Done _ -> "done"
  | Cancelled _ -> "cancelled"
;;

let task_is_claim_pool_candidate (task : Masc_domain.task) =
  Masc_domain.task_claim_next_action_is_claimable task
;;

let reconcile_agent_current_task_with_prepared_backlog
      config
      ?(touch_last_seen = true)
      ~agent_name
      (prepared : prepared_backlog)
  =
  let agent_file =
    Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json")
  in
  if path_exists config agent_file
  then
    with_file_lock config agent_file (fun () ->
      match read_agent config agent_file with
      | Ok agent ->
        (match agent.current_task with
         | Some task_id
           when not
                  (match
                     Task_id_map.find_opt
                       task_id
                       prepared.active_assignees_by_task_id
                   with
                   | Some assignee -> String.equal assignee agent.name
                   | None -> false) ->
           let updated_status =
             match agent.status with
             | Inactive -> Inactive
             | Active | Busy | Listening -> Active
           in
           let updated =
             { agent with
               status = updated_status
             ; current_task = None
             ; last_seen = (if touch_last_seen then now_iso () else agent.last_seen)
             }
           in
           Workspace_agent_record.write config agent_file ~previous:(Some agent) updated;
           log_event
             config
             (`Assoc
                 [ "type", `String "agent_current_task_reconciled"
                 ; "agent", `String agent.name
                 ; "ts", `String (now_iso ())
                 ])
         | Some _ | None -> ())
      | Error msg -> Log.Misc.error "agent state reconcile failed: %s" msg)
;;

(** Claim next highest priority unclaimed task.

    Scheduling logic:
    - Uses the task's explicit priority without time-derived rewriting
    - Within the same priority, prefers older tasks (FIFO) *)
let claim_next_r
      config
      ~agent_name
      ?(auto_start = false)
      ()
  =
  ensure_initialized config;
  let lock_path = backlog_lock_path config in
  let claim_under_lock () =
    try
      match read_prepared_backlog_r config with
      | Error msg -> Claim_next_error msg
      | Ok prepared ->
        let backlog = prepared.backlog in
        reconcile_agent_current_task_with_prepared_backlog config ~agent_name prepared;
        let working_tasks = backlog.tasks in
        (* Eligibility and the claim outcome are one decision
           ([Workspace_task_lifecycle.resolve_claim]).
           [prepared.claimable_ordered_tasks] is pre-sorted by
           [(priority, created_at, id)] and pre-filtered by
           [task_claim_next_action_is_claimable] once per decoded backlog
           snapshot. *)
        let now = now_iso () in
        let same_actor a = Workspace_task_classify.same_task_actor config a agent_name in
        let resolves_claimable (t : Masc_domain.task) =
          match
            Workspace_task_lifecycle.resolve_claim
              ~same_actor ~agent_name ~now t
          with
          | Workspace_task_lifecycle.Worker_claim _ -> true
          | Workspace_task_lifecycle.Self_owned
          | Workspace_task_lifecycle.Held_by_other _
          | Workspace_task_lifecycle.Held_terminal _
          | Workspace_task_lifecycle.Held_pending_verdict _ -> false
        in
        let unclaimed =
          prepared.claimable_ordered_tasks
          |> List.filter resolves_claimable
        in
        (match unclaimed with
         | [] -> Claim_next_no_unclaimed
         | task :: _ ->
           (* [unclaimed] admits only Todo tasks for which [resolve_claim]
              returns [Worker_claim]. The remaining arms are defensive and must
              not make AwaitingVerification eligible: that status belongs to
              the out-of-band completion-authority lane. *)
           let claimed_status =
             match
               Workspace_task_lifecycle.resolve_claim
                 ~same_actor ~agent_name ~now task
             with
             | Workspace_task_lifecycle.Worker_claim s -> s
             | Workspace_task_lifecycle.Self_owned
             | Workspace_task_lifecycle.Held_by_other _
             | Workspace_task_lifecycle.Held_terminal _
             | Workspace_task_lifecycle.Held_pending_verdict _ ->
               Masc_domain.Claimed { assignee = agent_name; claimed_at = now }
           in
           let final_status =
             if auto_start
             then Masc_domain.InProgress { assignee = agent_name; started_at = now }
             else claimed_status
           in
           let new_tasks =
             List.map
               (fun (t : task) ->
                  if t.id = task.id
                  then { t with task_status = final_status }
                  else t)
               working_tasks
           in
           (* [write_backlog] stamps version/last_updated at the commit point. *)
           let new_backlog = { backlog with tasks = new_tasks } in
           write_backlog
             ~after_commit:(fun () ->
               Task_cache_invariant.clear_stale_agent_task config
                 ~cause:Task_cache_invariant.After_commit
                 ~agent_name ~task_id:task.id ~status:final_status
                 ~module_name:"claim_next_r.claim")
             config new_backlog;
           let run_claim_next_post_commit label f =
             Workspace_task_claim.run_post_commit
               ~task_id:task.id
               ~agent_name
               ~action:"claim_next"
               label
               f
           in
           (* Update agent status — takes [with_file_lock] on the
             agent file via [Workspace_task.update_local_agent_state] to
             keep the record consistent with concurrent task transitions
             that hold the agent-file lock (PR #6634). *)
           run_claim_next_post_commit "agent_state" (fun () ->
             Workspace_task.update_local_agent_state config ~agent_name (fun agent ->
               { agent with status = Busy; current_task = Some task.id }));
           run_claim_next_post_commit "activity" (fun () ->
             Workspace_task.emit_task_activity
               config
               ~agent_name
               ~task_id:task.id
               ~kind:(Event_kind.Task.to_string Event_kind.Task.Claimed)
               ~payload:
                 (`Assoc
                     [ "task_id", `String task.id
                     ; "title", `String task.title
                     ; "priority", `Int task.priority
                     ]));
           run_claim_next_post_commit "claim_next_log" (fun () ->
             log_event
               config
               (`Assoc
                   [ "type", `String "task_claim_next"
                   ; "agent", `String agent_name
                   ; "task", `String task.id
                   ; "priority", `Int task.priority
                   ; "ts", `String now
                   ]));
           run_claim_next_post_commit "observe_transition" (fun () ->
             Workspace_task.observe_task_transition
               config
               ~agent_name
               ~task_id:task.id
               ~transition:Masc_domain.Claim
               ~details:
                 (Workspace_task.task_transition_details
                    ~from_status:task.task_status
                    ~to_status:claimed_status
                    ()));
           if auto_start
           then
             Workspace_task_claim.emit_auto_start_side_effects
               config
               ~agent_name
               ~task_id:task.id
               ~from_status:claimed_status
               ~to_status:final_status;
           let base_message =
             Printf.sprintf
               "%s auto-claimed [P%d] %s: %s"
               agent_name
               task.priority
               task.id
               task.title
           in
           let message =
             if auto_start
             then base_message ^ " Task auto-started — begin work now."
             else base_message
           in
           Claim_next_claimed
             { task_id = task.id
             ; title = task.title
             ; priority = task.priority
             ; message
             })
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Claim_next_error (Printexc.to_string e)
  in
  match with_file_lock_r config lock_path claim_under_lock with
  | Ok result -> result
  | Error err -> Claim_next_error (Masc_domain.masc_error_to_string err)
;;
