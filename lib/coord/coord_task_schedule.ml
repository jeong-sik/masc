(** Coord_task_schedule — Scheduling: claim_next, release_stale_claims.

    Extracted from Coord_task to separate scheduling logic (priority queue,
    stale detection, auto-release) from task CRUD and state transitions. *)

open Types
include Coord_utils
include Coord_state

let task_is_claim_pool_candidate (task : Types.task) =
  match task.task_status with
  | Todo -> Option.is_none task.do_not_reclaim_reason
  | Claimed _ | InProgress _ | AwaitingVerification _ | Done _ | Cancelled _ ->
      false

type verification_claim_state =
  [ `Pending | `Assigned | `Passed | `Rejected ]

let verification_claim_state_of_status
    (status : Coord_verification_store.request_status) =
  match status with
  | `Pending -> `Pending
  | `Assigned _ -> `Assigned
  | `Completed `Pass -> `Passed
  | `Completed (`Fail _ | `Partial _) ->
      `Rejected

let latest_verification_status_by_task config =
  let latest = Hashtbl.create 16 in
  Coord_verification_store.list_request_headers config.base_path
  |> List.iter (fun (req : Coord_verification_store.request_header) ->
         let state = verification_claim_state_of_status req.status in
         match Hashtbl.find_opt latest req.task_id with
         | Some (latest_created_at, _) when latest_created_at >= req.created_at ->
             ()
         | Some _ | None ->
             Hashtbl.replace latest req.task_id (req.created_at, state));
  latest

let verification_blocks_claim latest_status_by_task (task : Types.task) =
  match Hashtbl.find_opt latest_status_by_task task.id with
  | Some (_, `Pending)
  | Some (_, `Assigned)
  | Some (_, `Rejected) -> true
  | Some (_, `Passed)
  | None -> false

let agent_current_task_matches_backlog backlog ~agent_name task_id =
  match
    List.find_opt
      (fun (task : Types.task) -> String.equal task.id task_id)
      backlog.tasks
  with
  | Some task -> (
      match task.task_status with
      | Claimed { assignee; _ } | InProgress { assignee; _ }
      | AwaitingVerification { assignee; _ } ->
          String.equal assignee agent_name
      | Todo | Done _ | Cancelled _ -> false)
  | None -> false

let reconcile_agent_current_task_with_backlog config ~agent_name backlog =
  let agent_file =
    Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json")
  in
  if path_exists config agent_file then
    with_file_lock config agent_file (fun () ->
      match read_agent_with_repair config agent_file with
      | Ok agent -> (
          match agent.current_task with
          | Some task_id
            when not
                   (agent_current_task_matches_backlog backlog ~agent_name task_id)
            ->
              let updated_status =
                match agent.status with
                | Inactive -> Inactive
                | Active | Busy | Listening -> Active
              in
              let updated =
                {
                  agent with
                  status = updated_status;
                  current_task = None;
                  last_seen = now_iso ();
                }
              in
              write_json config agent_file (agent_to_yojson updated);
              log_event config
                (Printf.sprintf
                   "{\"type\":\"agent_current_task_reconciled\",\"agent\":\"%s\",\"stale_task\":\"%s\",\"ts\":\"%s\"}"
                   agent_name task_id (now_iso ()))
          | Some _ | None -> ())
      | Error msg ->
          Log.Misc.error "agent state reconcile failed: %s" msg)

(** Claim next highest priority unclaimed task.
    Optional [exclude_task_ids] prevents re-claiming known bad tasks in the
    same loop run.  Optional [task_filter] lets callers scope eligible work
    while the backlog lock is held.

    Scheduling logic:
    - Auto-releases any previous claim held by this agent (BUG-004)
    - Applies starvation prevention: tasks waiting >24h get priority boost
    - Within same effective priority, prefers older tasks (FIFO) *)
let claim_next_r
      config
      ~agent_name
      ?(exclude_task_ids = [])
      ?(task_filter = fun _ -> true)
      ()
  =
  ensure_initialized config;

  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  with_file_lock config backlog_path (fun () ->
    try
      match read_backlog_r config with
      | Error msg -> Claim_next_error msg
      | Ok backlog ->
      reconcile_agent_current_task_with_backlog config ~agent_name backlog;

      (* BUG-004: Detect and auto-release previous claim to prevent orphaned tasks.
         If this agent already holds a Claimed or InProgress task, release it
         back to Todo before proceeding. This prevents "claimed but orphaned"
         tasks that permanently block the backlog. *)
      let previous_claim = List.find_opt (fun (t : Types.task) ->
        match t.task_status with
        | Claimed { assignee; _ } | InProgress { assignee; _ }
        | AwaitingVerification { assignee; _ } ->
            String.equal assignee agent_name
        | Todo | Done _ | Cancelled _ -> false
      ) backlog.tasks in
      let observe_auto_release () =
        match previous_claim with
        | Some prev ->
            Coord_task.observe_task_transition config ~agent_name ~task_id:prev.id
              ~transition:Types.Release
              ~details:
                (Coord_task.task_transition_details ~from_status:prev.task_status
                   ~to_status:Types.Todo
                   ~reason:"auto_release_before_claim_next" ())
        | None -> ()
      in
      let released_task_id, working_tasks = match previous_claim with
        | None -> None, backlog.tasks
        | Some prev ->
            log_event config (Printf.sprintf
              "{\"type\":\"task_claim_next_auto_release\",\"agent\":\"%s\",\"released_task\":\"%s\",\"ts\":\"%s\"}"
              agent_name prev.id (now_iso ()));
            (* No broadcast — internal state transition, log_event suffices. *)
            let updated = List.map (fun (t : Types.task) ->
              if String.equal t.id prev.id then { t with task_status = Todo }
              else t
            ) backlog.tasks in
            Some prev.id, updated
      in

      (* Starvation prevention: Calculate effective priority
         Tasks waiting >24h get priority boost (-1 per 24h, min 1) *)
      let now = Time_compat.now () in
      (* Reuse canonical UTC parser from Types_core *)
      let parse_time = Types_core.parse_iso8601_opt in
      let effective_priority (task : Types.task) =
        let age_hours =
          match parse_time task.created_at with
          | Some created -> (now -. created) /. 3600.0
          | None -> 0.0
        in
        let boost = Float.to_int (Float.round (age_hours /. 24.0)) in
        max 1 (task.priority - boost)
      in

      (* Find highest priority (lowest number) unclaimed task
         Within same priority, prefer older tasks (FIFO) *)
      let sorted = List.sort (fun a b ->
        let priority_cmp = compare (effective_priority a) (effective_priority b) in
        if priority_cmp <> 0 then priority_cmp
        else compare b.created_at a.created_at  (* Newer first to unblock stale queues *)
      ) working_tasks in
      (* Identify blocked Todo tasks for observability *)
      let all_todo = List.filter (fun (t : Types.task) ->
        t.task_status = Types.Todo
      ) sorted in
      let blocked_todo = List.filter (fun (t : Types.task) ->
        Option.is_some t.do_not_reclaim_reason
      ) all_todo in
      let latest_verification_status = latest_verification_status_by_task config in
      let verification_blocked_todo =
        List.filter (verification_blocks_claim latest_verification_status) all_todo
      in
      if blocked_todo <> [] then
        log_event config
          (Printf.sprintf
             "{\"type\":\"task_claim_next_skip_blocked\",\"agent\":\"%s\",\"blocked\":%d,\"ts\":\"%s\"}"
             agent_name (List.length blocked_todo) (now_iso ()));
      if verification_blocked_todo <> [] then
        log_event config
          (Printf.sprintf
             "{\"type\":\"task_claim_next_skip_verification\",\"agent\":\"%s\",\"blocked\":%d,\"ts\":\"%s\"}"
             agent_name (List.length verification_blocked_todo) (now_iso ()));

      let unclaimed = List.filter task_is_claim_pool_candidate sorted in
      (* Also exclude the just-released task: the agent is moving on,
         re-claiming the same task would be a no-op loop. *)
      let blocked_ids =
        List.map (fun (t : Types.task) -> t.id) blocked_todo
        @ List.map (fun (t : Types.task) -> t.id) verification_blocked_todo
        |> List.sort_uniq String.compare
      in
      let all_excluded = match released_task_id with
        | Some rid -> rid :: (blocked_ids @ exclude_task_ids)
        | None -> blocked_ids @ exclude_task_ids
      in
      let task_filter_excluded =
        List.filter
          (fun (t : task) -> (not (List.mem t.id all_excluded)) && not (task_filter t))
          unclaimed
      in
      let eligible =
        List.filter
          (fun (t : task) -> (not (List.mem t.id all_excluded)) && task_filter t)
          unclaimed
      in

      (* Helper: clear agent current_task and reset status after auto-release
         when no replacement task can be claimed.  Delegates to
         [Coord_task.update_local_agent_state] so the agent-file write
         holds [with_file_lock] on the agent file itself, matching the
         discipline used by [Coord_task] transitions (PR #6634). *)
      let clear_agent_state_after_release () =
        match released_task_id with
        | Some _ ->
            Coord_task.update_local_agent_state config ~agent_name (fun agent ->
              { agent with status = Active; current_task = None })
        | None -> ()
      in

      match all_todo, eligible with
      | [], _ ->
          (* Even if we released a task, there may be nothing else to claim.
             Write the release if it happened. *)
          (match released_task_id with
           | Some _ ->
               let new_backlog = {
                 tasks = working_tasks;
                 last_updated = now_iso ();
                 version = backlog.version + 1;
               } in
               write_backlog config new_backlog;
               observe_auto_release ()
           | None -> ());
          clear_agent_state_after_release ();
          Claim_next_no_unclaimed
      | _ :: _, [] ->
          (match released_task_id with
           | Some _ ->
               let new_backlog = {
                 tasks = working_tasks;
                 last_updated = now_iso ();
                 version = backlog.version + 1;
               } in
               write_backlog config new_backlog;
               observe_auto_release ()
           | None -> ());
          clear_agent_state_after_release ();
          Claim_next_no_eligible
            {
              excluded_count =
                List.length all_excluded + List.length task_filter_excluded;
            }
      | _ :: _, task :: _ ->
          (* Claim this task *)
          let new_tasks = List.map (fun (t : task) ->
            if t.id = task.id then
              { t with task_status = Claimed {
                  assignee = agent_name;
                  claimed_at = now_iso ()
                }
              }
            else t
          ) working_tasks in

          let new_backlog = {
            tasks = new_tasks;
            last_updated = now_iso ();
            version = backlog.version + 1;
          } in
          write_backlog config new_backlog;

          (* Update agent status — takes [with_file_lock] on the
             agent file via [Coord_task.update_local_agent_state] to
             keep the record consistent with concurrent
             [Coord_agent.update_agent_r] or other task transitions
             that hold the agent-file lock (PR #6634). *)
          Coord_task.update_local_agent_state config ~agent_name (fun agent ->
            { agent with status = Busy; current_task = Some task.id });

          (* No broadcast — log_event + emit_task_activity below are sufficient. *)
          (match released_task_id with
           | Some rid ->
               Coord_task.emit_task_activity config ~agent_name ~task_id:rid
                 ~kind:(Event_kind.Task.to_string Event_kind.Task.Released)
                 ~payload:(`Assoc [ ("task_id", `String rid) ]);
               observe_auto_release ()
           | None -> ());
          Coord_task.emit_task_activity config ~agent_name ~task_id:task.id
            ~kind:(Event_kind.Task.to_string Event_kind.Task.Claimed)
            ~payload:
              (`Assoc
                [
                  ("task_id", `String task.id);
                  ("title", `String task.title);
                  ("priority", `Int task.priority);
                ]);

          log_event config (Printf.sprintf
            "{\"type\":\"task_claim_next\",\"agent\":\"%s\",\"task\":\"%s\",\"priority\":%d,\"ts\":\"%s\"}"
            agent_name task.id task.priority (now_iso ()));
          Coord_task.observe_task_transition config ~agent_name ~task_id:task.id
            ~transition:Types.Claim
            ~details:
              (Coord_task.task_transition_details ~from_status:Types.Todo
                 ~to_status:
                   (Types.Claimed
                      { assignee = agent_name; claimed_at = now_iso () })
                 ());

          let message = match released_task_id with
            | Some rid ->
                Printf.sprintf "⚠ %s auto-released %s, then claimed [P%d] %s: %s"
                  agent_name rid task.priority task.id task.title
            | None ->
                Printf.sprintf "✅ %s auto-claimed [P%d] %s: %s"
                  agent_name task.priority task.id task.title
          in
          Claim_next_claimed {
            task_id = task.id;
            title = task.title;
            priority = task.priority;
            released_task_id;
            message;
          }
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e ->
      Claim_next_error (Printexc.to_string e)
  )

(** Claim next highest priority unclaimed task (legacy string API). *)
let claim_next config ~agent_name =
  match claim_next_r config ~agent_name () with
  | Claim_next_claimed { message; _ } -> message
  | Claim_next_no_unclaimed -> "📋 No unclaimed tasks. ACTION: Stop task-checking — nothing to claim."
  | Claim_next_no_eligible { excluded_count } ->
      Printf.sprintf
        "📋 No eligible unclaimed tasks. ACTION: Stop task-checking — blocked/excluded=%d."
        excluded_count
  | Claim_next_error e -> Printf.sprintf "❌ Error: %s" e

(** Release stale task claims older than [ttl_seconds].
    A Claimed or InProgress task whose assignee has no recent heartbeat
    (per the zombie threshold) is considered stale.
    Returns list of (task_id, assignee) pairs that were released. *)
let release_stale_claims config ~ttl_seconds =
  ensure_initialized config;
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  with_file_lock config backlog_path (fun () ->
    match read_backlog_r config with
    | Error msg ->
        Log.Orchestrator.error
          "[stale-claims] skipping backlog mutation due to read failure: %s"
          msg;
        []
    | Ok backlog ->
        let now_str = now_iso () in
        let now_f = Time_compat.now () in
        let stale_tasks = ref [] in
        let updated_tasks = List.map (fun (task : task) ->
          match task.task_status with
          | Claimed { assignee; claimed_at } ->
              let ts = parse_iso8601 ~default_time:(now_f -. ttl_seconds -. 1.0) claimed_at in
              if now_f -. ts > ttl_seconds then begin
                stale_tasks := (task.id, assignee) :: !stale_tasks;
                log_event config (Printf.sprintf
                  "{\"type\":\"stale_claim_released\",\"task_id\":\"%s\",\"assignee\":\"%s\",\"age_s\":%.0f,\"ts\":\"%s\"}"
                  task.id assignee (now_f -. ts) now_str);
                { task with task_status = Todo }
              end else task
          | InProgress { assignee; started_at } ->
              let ts = parse_iso8601 ~default_time:(now_f -. ttl_seconds -. 1.0) started_at in
              if now_f -. ts > ttl_seconds then begin
                stale_tasks := (task.id, assignee) :: !stale_tasks;
                log_event config (Printf.sprintf
                  "{\"type\":\"stale_inprogress_released\",\"task_id\":\"%s\",\"assignee\":\"%s\",\"age_s\":%.0f,\"ts\":\"%s\"}"
                  task.id assignee (now_f -. ts) now_str);
                { task with task_status = Todo }
              end else task
          | AwaitingVerification _ -> task  (* leave alone; awaiting verifier *)
        | Todo | Done _ | Cancelled _ -> task
      ) backlog.tasks in
        if !stale_tasks <> [] then begin
          let updated_backlog = { tasks = updated_tasks; last_updated = now_str; version = backlog.version + 1 } in
          write_backlog config updated_backlog
        end;
        List.rev !stale_tasks
  )
