(** Workspace_task_schedule — Scheduling: claim_next.

    Extracted from Workspace_task to separate scheduling logic (priority queue,
    existing-claim preservation) from task CRUD and state
    transitions. *)

open Masc_domain
include Workspace_utils
include Workspace_state
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

let underscore_name = Workspace_task_receipts.underscore_name
let hyphen_name = Workspace_task_receipts.hyphen_name
let agent_record_keeper_name = Workspace_task_receipts.agent_record_keeper_name
let keeper_receipt_candidate_names = Workspace_task_receipts.keeper_receipt_candidate_names
let directory_exists = Workspace_task_receipts.directory_exists
let directory_entries = Workspace_task_receipts.directory_entries
let jsonl_files_under = Workspace_task_receipts.jsonl_files_under
let last_nonempty_line = Workspace_task_receipts.last_nonempty_line
let latest_json_in_receipt_dir = Workspace_task_receipts.latest_json_in_receipt_dir
let json_member_path = Workspace_task_receipts.json_member_path
let json_raw_string_path = Workspace_task_receipts.json_raw_string_path
let json_string_path = Workspace_task_receipts.json_string_path
let receipt_sort_key = Workspace_task_receipts.receipt_sort_key
let latest_execution_receipt_json = Workspace_task_receipts.latest_execution_receipt_json
let active_task_assignees_by_task_id backlog =
  let table = Hashtbl.create (List.length backlog.tasks) in
  List.iter
    (fun (task : Masc_domain.task) ->
       match task.task_status with
       | Claimed { assignee; _ } | InProgress { assignee; _ } ->
         Hashtbl.replace table task.id assignee
       | Todo | AwaitingVerification _ | Done _ | Cancelled _ -> ())
    backlog.tasks;
  table
;;

let agent_current_task_matches_assignments active_task_assignees ~agent_name task_id =
  match Hashtbl.find_opt active_task_assignees task_id with
  | Some assignee -> String.equal assignee agent_name
  | None -> false
;;

let reconcile_agent_current_task_record
      config
      ?(touch_last_seen = true)
      ~agent_file
      ~(agent : Masc_domain.agent)
      active_task_assignees
  =
  match agent.current_task with
  | Some task_id
    when not
           (agent_current_task_matches_assignments
              active_task_assignees
              ~agent_name:agent.name
              task_id) ->
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
    write_json config agent_file (agent_to_yojson updated);
    log_event
      config
      (`Assoc
          [ "type", `String "agent_current_task_reconciled"
          ; "agent", `String agent.name
          ; "ts", `String (now_iso ())
          ])
  | Some _ | None -> ()
;;

let reconcile_agent_current_task_with_assignments
      config
      ?(touch_last_seen = true)
      ~agent_name
      active_task_assignees
  =
  let agent_file =
    Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json")
  in
  if path_exists config agent_file
  then
    with_file_lock config agent_file (fun () ->
      match read_agent config agent_file with
      | Ok agent ->
        reconcile_agent_current_task_record
          config
          ~touch_last_seen
          ~agent_file
          ~agent
          active_task_assignees
      | Error msg -> Log.Misc.error "agent state reconcile failed: %s" msg)
;;

let reconcile_agent_current_task_with_backlog
      config
      ?(touch_last_seen = true)
      ~agent_name
      backlog
  =
  let active_task_assignees = active_task_assignees_by_task_id backlog in
  reconcile_agent_current_task_with_assignments
    config
    ~touch_last_seen
    ~agent_name
    active_task_assignees
;;

(** Claim next highest priority unclaimed task.
    Optional [exclude_task_ids] prevents re-claiming known bad tasks in the
    same loop run.  Optional [task_filter] lets callers scope eligible work
    while the backlog lock is held.

    Scheduling logic:
    - Preserves any active claim held by this agent; callers must explicitly
      release or finish before claiming different work.
    - Uses the task's explicit priority without time-derived rewriting
    - Within the same priority, prefers older tasks (FIFO) *)
let claim_next_r
      config
      ~agent_name
      ?(exclude_task_ids = [])
      ?(task_filter : Masc_domain.task -> bool = fun _ -> true)
      ?(hard_filter : Masc_domain.task -> bool = fun _ -> true)
      ?(allow_scope_fallback = false)
      ()
  =
  let exception Existing_claim of claim_next_result in
  ensure_initialized config;
  let lock_path = backlog_lock_path config in
  let claim_under_lock () =
    try
      match read_backlog_r config with
      | Error msg -> Claim_next_error msg, None
      | Ok backlog ->
        reconcile_agent_current_task_with_backlog config ~agent_name backlog;
        (* #10421: If this agent already holds a Claimed or InProgress task,
         return that task instead of implicitly releasing it.  Automatic
         release caused keeper hot-potato loops: a repeated claim_next call
         could drop InProgress work back to Todo and let another keeper steal
         it before the original owner had a chance to finish.  AwaitingVerification
         is still excluded: it is no longer active implementation work for
         the claimant. *)
        let active_owned_task_ids =
          Workspace_task.active_owned_task_ids_for_agent config ~agent_name backlog
        in
        let previous_claim =
          List.find_opt
            (fun (t : Masc_domain.task) ->
               List.mem t.id active_owned_task_ids)
            backlog.tasks
        in
        (match previous_claim with
         | None -> ()
         | Some prev ->
           let from_status = task_status_label prev.task_status in
           log_event
             config
             (`Assoc
                 [ "type", `String "task_claim_next_existing_task"
                 ; "agent", `String agent_name
                 ; "task", `String prev.id
                 ; "from_status", `String from_status
                 ; "reason", `String "existing_claim_preserved"
                 ; "ts", `String (now_iso ())
                 ]);
           Log.TaskState.info
             "task_claim_next preserved existing task: agent=%s task=%s from_status=%s — \
              finish or explicitly release before claiming different work (#10421)"
             agent_name
             prev.id
             from_status;
           Workspace_task.update_local_agent_state config ~agent_name (fun agent ->
             { agent with status = Busy; current_task = Some prev.id });
           let message =
             (* Shared with the claim-by-task_id refusal, which used to say only
                that a task was held. One constraint, one sentence. *)
             Workspace_task.held_tasks_refusal_message ~agent_name [ prev ]
           in
           raise
             (Existing_claim
                (Claim_next_claimed
                   { task_id = prev.id
                   ; title = prev.title
                   ; priority = prev.priority
                   ; message
                   ; scope_widened = false
                   })));
        let working_tasks = backlog.tasks in
        (* Explicit task priority is the scheduling input. Waiting time is
           observable through [created_at], but never rewrites that priority. *)
        let sorted =
          List.sort
            (fun a b ->
               let priority_cmp = compare a.priority b.priority in
               if priority_cmp <> 0
               then priority_cmp
               else compare a.created_at b.created_at)
            working_tasks
        in
        (* Eligibility and the claim outcome are one decision
           ([Workspace_task_lifecycle.resolve_claim]).
           [task_claim_next_action_is_claimable] still owns the Todo reclaim
           gate. *)
        let same_actor a = Workspace_task_classify.same_task_actor config a agent_name in
        let resolves_claimable (t : Masc_domain.task) =
          match
            Workspace_task_lifecycle.resolve_claim
              ~same_actor ~agent_name ~now:(now_iso ()) t
          with
          | Workspace_task_lifecycle.Worker_claim _ -> true
          | Workspace_task_lifecycle.Self_owned
          | Workspace_task_lifecycle.Held_by_other _
          | Workspace_task_lifecycle.Held_terminal _
          | Workspace_task_lifecycle.Held_pending_verdict _ -> false
        in
        let unclaimed =
          sorted
          |> List.filter Masc_domain.task_claim_next_action_is_claimable
          |> List.filter resolves_claimable
          (* [hard_filter] is a hard exclusion (e.g. self-author ownership): unlike
             [task_filter] it survives the [allow_scope_fallback] widening below,
             because it expresses an invariant the scheduler must never relax, not
             a goal scope that may be dropped to avoid starvation. Applying it here
             at the base makes both [scoped_eligible] and the widened set respect
             it. *)
          |> List.filter hard_filter
        in
        let all_excluded = exclude_task_ids in
        let task_filter_excluded =
          List.filter
            (fun (t : task) ->
               (not (List.mem t.id all_excluded)) && not (task_filter t))
            unclaimed
        in
        let eligible_from candidates =
          List.filter
            (fun (t : task) ->
               (not (List.mem t.id all_excluded)) && task_filter t)
            candidates
        in
        let scoped_eligible = eligible_from unclaimed in
        (* Goal-scope must not starve a keeper: when [allow_scope_fallback] and no
           scoped task passes [task_filter], widen to all_tasks. [all_excluded] is
           still enforced — only [task_filter] (the goal scope) is dropped — so an
           unscoped task can be claimed. Schedule-level companion to the RFC-0067 §1
           resolve-side fallback. *)
        let eligible, scope_widened =
          match scoped_eligible with
          | _ :: _ -> scoped_eligible, false
          | [] when allow_scope_fallback ->
            let widened =
              List.filter
                (fun (t : task) -> not (List.mem t.id all_excluded))
                unclaimed
            in
            (match widened with
             | _ :: _ -> widened, true
             | [] -> [], false)
          | [] -> scoped_eligible, false
        in
        let explicit_excluded_count = List.length exclude_task_ids in
        let no_eligible_excluded_count =
          List.length all_excluded + List.length task_filter_excluded
        in
        (match eligible with
         | [] when unclaimed = [] ->
           Claim_next_no_unclaimed, None
         | [] ->
           ( Claim_next_no_eligible
              { excluded_count = no_eligible_excluded_count
              ; scope_excluded_count = List.length task_filter_excluded
              ; explicit_excluded_count
              ; claim_pool_candidate_count = List.length unclaimed
              }
          , None )
         | task :: _ ->
           (* [unclaimed] admits only Todo tasks for which [resolve_claim]
              returns [Worker_claim]. The remaining arms are defensive and must
              not make AwaitingVerification eligible: that status belongs to
              the out-of-band completion-authority lane. *)
           let claimed_status =
             match
               Workspace_task_lifecycle.resolve_claim
                 ~same_actor ~agent_name ~now:(now_iso ()) task
             with
             | Workspace_task_lifecycle.Worker_claim s -> s
             | Workspace_task_lifecycle.Self_owned
             | Workspace_task_lifecycle.Held_by_other _
             | Workspace_task_lifecycle.Held_terminal _
             | Workspace_task_lifecycle.Held_pending_verdict _ ->
               Masc_domain.Claimed { assignee = agent_name; claimed_at = now_iso () }
           in
           let new_tasks =
             List.map
               (fun (t : task) ->
                  if t.id = task.id
                  then (
                    let t = Workspace_task.clear_reclaim_decision t in
                    { t with task_status = claimed_status })
                  else t)
               working_tasks
           in
           (* [write_backlog] stamps version/last_updated at the commit point. *)
           let new_backlog = { backlog with tasks = new_tasks } in
           write_backlog
             ~after_commit:(fun () ->
               Task_cache_invariant.clear_stale_agent_task config
                 ~cause:Task_cache_invariant.After_commit
                 ~agent_name ~task_id:task.id ~status:claimed_status
                 ~module_name:"claim_next_r.claim")
             config new_backlog;
           (* Update agent status — takes [with_file_lock] on the
             agent file via [Workspace_task.update_local_agent_state] to
             keep the record consistent with concurrent task transitions
             that hold the agent-file lock (PR #6634). *)
           Workspace_task.update_local_agent_state config ~agent_name (fun agent ->
             { agent with status = Busy; current_task = Some task.id });
           (* No broadcast — log_event + emit_task_activity below are sufficient. *)
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
                   ]);
           log_event
             config
             (`Assoc
                 [ "type", `String "task_claim_next"
                 ; "agent", `String agent_name
                 ; "task", `String task.id
                 ; "priority", `Int task.priority
                 ; "ts", `String (now_iso ())
                 ]);
           Workspace_task.observe_task_transition
             config
             ~agent_name
             ~task_id:task.id
             ~transition:Masc_domain.Claim
             ~details:
               (Workspace_task.task_transition_details
                  ~from_status:task.task_status
                  ~to_status:claimed_status
                  ());
          let message =
            Printf.sprintf
              "%s auto-claimed [P%d] %s: %s"
              agent_name
              task.priority
              task.id
              task.title
           in
          ( Claim_next_claimed
              { task_id = task.id
              ; title = task.title
              ; priority = task.priority
              ; message
              ; scope_widened
              }
          , Some task.id ))
    with
    | Existing_claim result -> result, None
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Claim_next_error (Printexc.to_string e), None
  in
  match with_file_lock_r config lock_path claim_under_lock with
  | Ok (result, _) -> result
  | Error err -> Claim_next_error (Masc_domain.masc_error_to_string err)
;;
