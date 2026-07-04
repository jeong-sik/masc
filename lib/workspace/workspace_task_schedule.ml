(** Workspace_task_schedule — Scheduling: claim_next, release_stale_claims.

    Extracted from Workspace_task to separate scheduling logic (priority queue,
    stale detection, existing-claim preservation) from task CRUD and state
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

(* RFC-0220 §3.2: verification state no longer gates the worker claim pool.
   The cross-store join (request_status -> claim eligibility) is removed: an
   AwaitingVerification obligation stays claimable by a verifier (§3.5), and a
   drifted Todo task with a dangling Pending evidence record is just a normal
   claimable Todo (the evidence record is no longer read for scheduling). This
   removal is the part that makes the §1.1 stranding disappear — there is
   nothing left to drift against. (The now-always-empty [verification_blocked_*]
   plumbing + the [verification_blocked_count] field are cosmetic dead code,
   removed in a follow-up per §11.) *)

let underscore_name = Workspace_task_receipts.underscore_name
let hyphen_name = Workspace_task_receipts.hyphen_name
let keeper_name_from_agent_name = Workspace_task_receipts.keeper_name_from_agent_name
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

let agent_current_task_matches_backlog backlog ~agent_name task_id =
  let active_task_assignees = active_task_assignees_by_task_id backlog in
  agent_current_task_matches_assignments active_task_assignees ~agent_name task_id
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
          ; "stale_task", `String task_id
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
      match read_agent_with_repair config agent_file with
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

let reconcile_all_agent_current_tasks_with_backlog
      config
      ?(touch_last_seen = true)
      backlog
  =
  let agents_path = agents_dir config in
  try
    if Sys.file_exists agents_path
    then (
      let active_task_assignees = active_task_assignees_by_task_id backlog in
      Sys.readdir agents_path
      |> Array.to_list
      |> List.filter (fun name -> Filename.check_suffix name ".json")
      |> List.iter (fun name ->
        Workspace_query.safe_yield ();
        let path = Filename.concat agents_path name in
        with_file_lock config path (fun () ->
          match read_agent_with_repair config path with
          | Ok (agent : Masc_domain.agent) ->
            reconcile_agent_current_task_record
              config
              ~touch_last_seen
              ~agent_file:path
              ~agent
              active_task_assignees
          | Error msg -> Log.Misc.error "agent state reconcile failed for %s: %s" name msg)))
  with
  | Sys_error msg -> Log.Misc.error "agent state reconcile scan failed: %s" msg
;;

let reconcile_all_agent_current_tasks_with_fresh_backlog ?(touch_last_seen = true) config =
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  with_file_lock config backlog_path (fun () ->
    let backlog = read_backlog config in
    reconcile_all_agent_current_tasks_with_backlog config ~touch_last_seen backlog;
    backlog)
;;

(** Claim next highest priority unclaimed task.
    Optional [exclude_task_ids] prevents re-claiming known bad tasks in the
    same loop run.  Optional [task_filter] lets callers scope eligible work
    while the backlog lock is held.

    Scheduling logic:
    - Preserves any active claim held by this agent; callers must explicitly
      release or finish before claiming different work.
    - Applies starvation prevention: tasks waiting >24h get priority boost
    - Within same effective priority, prefers older tasks (FIFO) *)
let claim_next_r
      config
      ~agent_name
      ?(exclude_task_ids = [])
      ?(task_filter : Masc_domain.task -> bool = fun _ -> true)
      ?(allow_scope_fallback = false)
      ()
  =
  let exception Existing_claim of claim_next_result in
  ensure_initialized config;
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
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
             Printf.sprintf
               "%s already holds [P%d] %s: %s. ACTION: Resume this task; do not call \
                claim_next again until it is done or explicitly released."
               agent_name
               prev.priority
               prev.id
               prev.title
           in
           raise
             (Existing_claim
                (Claim_next_claimed
                   { task_id = prev.id
                   ; title = prev.title
                   ; priority = prev.priority
                   ; released_task_id = None
                   ; message
                   ; scope_widened = false
                   })));
        let released_task_id, working_tasks = None, backlog.tasks in
        (* Starvation prevention: Calculate effective priority
         Tasks waiting >24h get priority boost (-1 per 24h, min 1) *)
        let now = Time_compat.now () in
        (* Reuse canonical UTC parser from Types_core *)
        let parse_time = Types_core.parse_iso8601_opt in
        let effective_priority (task : Masc_domain.task) =
          let age_hours =
            match parse_time task.created_at with
            | Some created -> (now -. created) /. Masc_time_constants.hour
            | None -> 0.0
          in
          let boost = Float.to_int (Float.round (age_hours /. 24.0)) in
          max 1 (task.priority - boost)
        in
        (* Find highest priority (lowest number) unclaimed task
         Within same priority, prefer older tasks (FIFO) *)
        let sorted =
          List.sort
            (fun a b ->
               let priority_cmp = compare (effective_priority a) (effective_priority b) in
               if priority_cmp <> 0
               then priority_cmp
               else compare a.created_at b.created_at)
            working_tasks
        in
        (* Identify blocked Todo tasks for observability *)
        let all_todo =
          List.filter
            (fun (t : Masc_domain.task) -> t.task_status = Masc_domain.Todo)
            sorted
        in
        let blocked_todo =
          List.filter
            (fun (t : Masc_domain.task) ->
               match Masc_domain.task_claim_next_action t with
               | Skip_claim (Claim_block_reclaim_policy _) -> true
               | Claim_now
               | Skip_claim (Claim_block_not_todo _) ->
                 false)
            all_todo
        in
        (* RFC-0220 §3.2: no verification-based exclusion from the claim pool. *)
        let verification_blocked_todo : Masc_domain.task list = [] in
        if blocked_todo <> []
        then
          log_event
            config
            (`Assoc
                [ "type", `String "task_claim_next_skip_blocked"
                ; "agent", `String agent_name
                ; "blocked", `Int (List.length blocked_todo)
                ; "ts", `String (now_iso ())
                ]);
        if verification_blocked_todo <> []
        then
          log_event
            config
            (`Assoc
                [ "type", `String "task_claim_next_skip_verification"
                ; "agent", `String agent_name
                ; "blocked", `Int (List.length verification_blocked_todo)
                ; "ts", `String (now_iso ())
                ]);
        (* RFC-0220 §3.5: eligibility and the claim outcome are one decision
           ([Workspace_task_lifecycle.resolve_claim]). A submitter's own
           [AwaitingVerification] resolves to [Self_owned] and is excluded here,
           so a worker never auto-claims (self-verifies) its own obligation; a
           cross-agent obligation resolves to [Verifier_claim] and stays
           eligible so the satisfier is always reachable.
           [task_claim_next_action_is_claimable] still owns the Todo reclaim
           gate. *)
        let same_actor a = Workspace_task_classify.same_task_actor config a agent_name in
        let resolves_claimable (t : Masc_domain.task) =
          match
            Workspace_task_lifecycle.resolve_claim
              ~same_actor ~agent_name ~now:(now_iso ()) t.task_status
          with
          | Workspace_task_lifecycle.Worker_claim _
          | Workspace_task_lifecycle.Verifier_claim _ -> true
          | Workspace_task_lifecycle.Self_owned
          | Workspace_task_lifecycle.Held_by_other _ -> false
        in
        let unclaimed =
          sorted
          |> List.filter Masc_domain.task_claim_next_action_is_claimable
          |> List.filter resolves_claimable
        in
        (* Also exclude the just-released task: the agent is moving on,
         re-claiming the same task would be a no-op loop. *)
        let blocked_ids =
          List.map (fun (t : Masc_domain.task) -> t.id) blocked_todo
          @ List.map (fun (t : Masc_domain.task) -> t.id) verification_blocked_todo
          |> List.sort_uniq String.compare
        in
        let all_excluded =
          match released_task_id with
          | Some rid -> rid :: (blocked_ids @ exclude_task_ids)
          | None -> blocked_ids @ exclude_task_ids
        in
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
        let explicit_excluded_count =
          List.length exclude_task_ids
          +
          match released_task_id with
          | Some _ -> 1
          | None -> 0
        in
        let no_eligible_excluded_count =
          List.length all_excluded + List.length task_filter_excluded
        in
        (* Helper: clear agent current_task and reset status after a legacy
         released_task_id path when no replacement task can be claimed. Delegates to
         [Workspace_task.update_local_agent_state] so the agent-file write
         holds [with_file_lock] on the agent file itself, matching the
         discipline used by [Workspace_task] transitions (PR #6634). *)
        let clear_agent_state_after_release () =
          match released_task_id with
          | Some rid ->
            (* RFC-0221 §3.2: flush stale current_task from in-memory context cache *)
            Task_cache_invariant.clear_stale_agent_task config ~agent_name
              ~task_id:rid ~status:Masc_domain.Todo ~module_name:"claim_next_r";
            Workspace_task.update_local_agent_state config ~agent_name (fun agent ->
              { agent with status = Active; current_task = None })
          | None -> ()
        in
        (match all_todo, eligible with
         | [], _ ->
           (* Even if we released a task, there may be nothing else to claim.
             Write the release if it happened. *)
           (match released_task_id with
            | Some _ ->
              let new_backlog =
                { tasks = working_tasks
                ; last_updated = now_iso ()
                ; version = backlog.version + 1
                }
              in
              write_backlog config new_backlog
            | None -> ());
           clear_agent_state_after_release ();
          Claim_next_no_unclaimed, None
         | _ :: _, [] ->
           (match released_task_id with
            | Some _ ->
              let new_backlog =
                { tasks = working_tasks
                ; last_updated = now_iso ()
                ; version = backlog.version + 1
                }
              in
              write_backlog config new_backlog
            | None -> ());
           clear_agent_state_after_release ();
          ( Claim_next_no_eligible
              { excluded_count = no_eligible_excluded_count
              ; blocked_count = List.length blocked_todo
              ; verification_blocked_count = List.length verification_blocked_todo
              ; scope_excluded_count = List.length task_filter_excluded
              ; explicit_excluded_count
              ; claim_pool_candidate_count = List.length unclaimed
              }
          , None )
         | _ :: _, task :: _ ->
           (* Claim this task. [resolve_claim] yields the post-claim status:
              [Claimed] for a Todo worker claim, or a verifier-bound
              [AwaitingVerification] for a cross-agent verification claim
              (RFC-0220 §3.5 — preserve the obligation as the satisfier, do not
              clobber it to [Claimed]). The [Self_owned]/[Held_by_other] arms
              are unreachable here: [unclaimed] admits only tasks that resolve
              to a claim (same [resolve_claim]); the defensive fallback keeps
              the worker-claim behavior rather than raising on the claim path. *)
           let claimed_status =
             match
               Workspace_task_lifecycle.resolve_claim
                 ~same_actor ~agent_name ~now:(now_iso ()) task.task_status
             with
             | Workspace_task_lifecycle.Worker_claim s
             | Workspace_task_lifecycle.Verifier_claim s -> s
             | Workspace_task_lifecycle.Self_owned
             | Workspace_task_lifecycle.Held_by_other _ ->
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
           let new_backlog =
             { tasks = new_tasks
             ; last_updated = now_iso ()
             ; version = backlog.version + 1
             }
           in
           write_backlog
             ~after_commit:(fun () ->
               Task_cache_invariant.clear_stale_agent_task config
                 ~agent_name ~task_id:task.id ~status:claimed_status
                 ~module_name:"claim_next_r.claim")
             config new_backlog;
           (* Update agent status — takes [with_file_lock] on the
             agent file via [Workspace_task.update_local_agent_state] to
             keep the record consistent with concurrent
             [Workspace_agent.update_agent_r] or other task transitions
             that hold the agent-file lock (PR #6634). *)
           Workspace_task.update_local_agent_state config ~agent_name (fun agent ->
             { agent with status = Busy; current_task = Some task.id });
           (* No broadcast — log_event + emit_task_activity below are sufficient. *)
           (match released_task_id with
            | Some rid ->
              Workspace_task.emit_task_activity
                config
                ~agent_name
                ~task_id:rid
                ~kind:(Event_kind.Task.to_string Event_kind.Task.Released)
                ~payload:(`Assoc [ "task_id", `String rid ])
            | None -> ());
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
            match released_task_id with
            | Some rid ->
               Printf.sprintf
                 "%s released %s, then claimed [P%d] %s: %s"
                 agent_name
                 rid
                 task.priority
                 task.id
                 task.title
             | None ->
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
              ; released_task_id
              ; message
              ; scope_widened
              }
          , Some task.id ))
    with
    | Existing_claim result -> result, None
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Claim_next_error (Printexc.to_string e), None
  in
  match with_file_lock_r config backlog_path claim_under_lock with
  | Ok (result, _) -> result
  | Error err -> Claim_next_error (Masc_domain.masc_error_to_string err)
;;

(** Claim next highest priority unclaimed task (legacy string API). *)
let claim_next config ~agent_name =
  match claim_next_r config ~agent_name () with
  | Claim_next_claimed { message; _ } -> message
  | Claim_next_no_unclaimed ->
    "No unclaimed tasks. ACTION: Stop task-checking — nothing to claim."
  | Claim_next_no_eligible
      { excluded_count
      ; scope_excluded_count
      ; verification_blocked_count
      ; _
      } ->
    Printf.sprintf
      "No eligible unclaimed tasks. ACTION: Stop task-checking — \
       blocked/excluded=%d (goal_scope_or_filter=%d, verification=%d)."
      excluded_count
      scope_excluded_count
      verification_blocked_count
  | Claim_next_error e -> Printf.sprintf "Error: %s" e
;;

(** Release stale task claims older than [ttl_seconds].
    A Claimed or InProgress task whose assignee has no recent heartbeat
    and whose task-status timestamp exceeds the TTL is considered stale.
    Returns list of (task_id, assignee) pairs that were released. *)
let release_stale_claims config ~ttl_seconds =
  ensure_initialized config;
  match read_backlog_r config with
  | Error msg ->
    Log.TaskState.warn "release_stale_claims: skipped unreadable backlog: %s" msg;
    []
  | Ok _ ->
    let now = Time_compat.now () in
    let status_timestamp = function
      | Masc_domain.Claimed { claimed_at; _ } -> Some claimed_at
      | Masc_domain.InProgress { started_at; _ } -> Some started_at
      | Masc_domain.Todo
      | Masc_domain.AwaitingVerification _
      | Masc_domain.Done _
      | Masc_domain.Cancelled _ -> None
    in
    let older_than_ttl task =
      match status_timestamp task.task_status with
      | None -> false
      | Some raw_ts ->
        (match Masc_domain.parse_iso8601_opt raw_ts with
         | Some ts -> now -. ts > ttl_seconds
         | None ->
           Log.TaskState.warn
             "release_stale_claims: refusing to release task=%s with unparsable \
              status timestamp %S"
             task.id
             raw_ts;
           false)
    in
    let release_one ((task : Masc_domain.task), assignee) =
      if not (older_than_ttl task)
      then None
      else (
        match
          Workspace_task.force_release_task_r
            config
            ~agent_name:"keeper-stale-claim-gc"
            ~task_id:task.id
            ()
        with
        | Ok _ ->
          Task_cache_invariant.clear_stale_agent_task
            config
            ~agent_name:assignee
            ~task_id:task.id
            ~status:Masc_domain.Todo
            ~module_name:"release_stale_claims";
          Some (task.id, assignee)
        | Error err ->
          log_event
            config
            (`Assoc
                [ "type", `String "stale_claim_release_error"
                ; "task_id", `String task.id
                ; "agent", `String assignee
                ; "error", `String (Masc_domain.masc_error_to_string err)
                ; "ts", `String (now_iso ())
                ]);
          None)
    in
    Workspace_query.audit_orphan_tasks config |> List.filter_map release_one
;;
