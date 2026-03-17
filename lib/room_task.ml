(** Room_task — Task lifecycle: add, claim, transition, complete, cancel, claim_next. *)

open Types
include Room_utils
include Room_state

(** Add task *)
let add_task config ~title ~priority ~description =
  ensure_initialized config;

  let backlog = read_backlog config in
  let task_id = Printf.sprintf "task-%03d" (next_task_number config backlog) in

  let new_task = {
    id = task_id;
    title;
    description;
    task_status = Todo;
    priority;
    files = [];
    created_at = now_iso ();
    worktree = None;  (* Linked when worktree is created *)
    required_role = Agent_identity.Unassigned;
  } in

  let new_backlog = {
    tasks = backlog.tasks @ [new_task];
    last_updated = now_iso ();
    version = backlog.version + 1;
  } in
  write_backlog config new_backlog;

  let _ = broadcast config ~from_agent:"system" ~content:(Printf.sprintf "📋 New quest: %s" title) in
  Printf.sprintf "✅ Added %s: %s" task_id title

(** Add task with a required role constraint *)
let add_task_with_role config ~title ~priority ~description ~required_role =
  ensure_initialized config;

  let backlog = read_backlog config in
  let task_id = Printf.sprintf "task-%03d" (next_task_number config backlog) in

  let new_task = {
    id = task_id;
    title;
    description;
    task_status = Todo;
    priority;
    files = [];
    created_at = now_iso ();
    worktree = None;
    required_role;
  } in

  let new_backlog = {
    tasks = backlog.tasks @ [new_task];
    last_updated = now_iso ();
    version = backlog.version + 1;
  } in
  write_backlog config new_backlog;

  let role_str = Agent_identity.role_to_string required_role in
  let _ = broadcast config ~from_agent:"system"
    ~content:(Printf.sprintf "📋 New quest: %s (requires: %s)" title role_str) in
  Printf.sprintf "✅ Added %s: %s (required_role: %s)" task_id title role_str

(** Add multiple tasks in a batch *)
let batch_add_tasks config tasks =
  ensure_initialized config;
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  with_file_lock config backlog_path (fun () ->
    try
      let backlog = read_backlog config in
      let next_num = ref (next_task_number config backlog) in
      let added_tasks = List.map (fun (title, priority, description) ->
        let task_id = Printf.sprintf "task-%03d" !next_num in
        incr next_num;
        {
          id = task_id;
          title;
          description;
          task_status = Todo;
          priority;
          files = [];
          created_at = now_iso ();
          worktree = None;
          required_role = Agent_identity.Unassigned;
        }
      ) tasks in
      let new_backlog = {
        tasks = backlog.tasks @ added_tasks;
        last_updated = now_iso ();
        version = backlog.version + 1;
      } in
      write_backlog config new_backlog;
      let summary = String.concat ", " (List.map (fun (t : Types.task) -> t.id) added_tasks) in
      let msg = Printf.sprintf "📋 New batch of %d quests added: %s" (List.length added_tasks) summary in
      let _ = broadcast config ~from_agent:"system" ~content:msg in
      Printf.sprintf "✅ Added %d tasks: %s" (List.length added_tasks) summary
    with e ->
      Printf.sprintf "❌ Error adding batch tasks: %s" (Printexc.to_string e)
  )

(** Claim task with file locking (TOCTOU prevention) *)
let claim_task config ~agent_name ~task_id =
  ensure_initialized config;

  (* Validate inputs *)
  match validate_agent_name agent_name, validate_task_id task_id with
  | Error e, _ -> Printf.sprintf "❌ %s" e
  | _, Error e -> Printf.sprintf "❌ %s" e
  | Ok _, Ok _ ->

  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  with_file_lock config backlog_path (fun () ->
    try
      let backlog = read_backlog config in
      let found = ref false in
      let already_claimed = ref None in
      let new_tasks = List.map (fun task ->
        if task.id = task_id then begin
          found := true;
          match task.task_status with
          | Todo ->
              { task with task_status = Claimed { assignee = agent_name; claimed_at = now_iso () } }
          | Claimed { assignee; _ } | InProgress { assignee; _ } | Done { assignee; _ } | Cancelled { cancelled_by = assignee; _ } ->
              already_claimed := Some assignee;
              task
        end else task
      ) backlog.tasks in
      if not !found then
        Printf.sprintf "❌ Task %s not found" task_id
      else match !already_claimed with
        | Some other -> Printf.sprintf "⚠ Task %s is already claimed by %s" task_id other
        | None ->
            let new_backlog = {
              tasks = new_tasks;
              last_updated = now_iso ();
              version = backlog.version + 1;
            } in
            write_backlog config new_backlog;
            let agent_file = Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json") in
            if Sys.file_exists agent_file then begin
              let json = read_json config agent_file in
              match agent_of_yojson json with
              | Ok agent ->
                  let updated = { agent with status = Busy; current_task = Some task_id } in
                  write_json config agent_file (agent_to_yojson updated)
              | Error msg ->
                  Log.Misc.error "agent state write failed: %s" msg
            end;
            let _ = broadcast config ~from_agent:agent_name ~content:(Printf.sprintf "📋 Claimed %s" task_id) in
            log_event config (Printf.sprintf
              "{\"type\":\"task_claim\",\"agent\":\"%s\",\"task\":\"%s\",\"ts\":\"%s\"}"
              agent_name task_id (now_iso ()));
            Printf.sprintf "✅ %s claimed %s" agent_name task_id
    with e ->
      Printf.sprintf "❌ Error: %s" (Printexc.to_string e)
  )

(** Result-returning version of claim_task for type-safe error handling.
    When [agent_role] is provided and the task has a [required_role],
    the claim is rejected if the roles do not match. *)
let claim_task_r config ~agent_name ~task_id
    ?(agent_role = Agent_identity.Unassigned) () : string Types.masc_result =
  if not (is_initialized config) then Error Types.NotInitialized
  else match validate_agent_name_r agent_name, validate_task_id_r task_id with
  | Error e, _ -> Error e
  | _, Error e -> Error e
  | Ok _, Ok _ ->
    (* BUG-005: Verify agent has joined before allowing claim.
       Single path: agents_dir derives from config.scope. *)
    let actual_name = resolve_agent_name config agent_name in
    let filename = safe_filename actual_name ^ ".json" in
    let agent_path = Filename.concat (agents_dir config) filename in
    let agent_joined = path_exists config agent_path in
    if not agent_joined then
      Error (Types.AgentNotJoined actual_name)
    else
    let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
    with_file_lock config backlog_path (fun () ->
      try
        let backlog = read_backlog config in
        (* Check role constraint before attempting claim *)
        let target_task = List.find_opt (fun t -> t.id = task_id) backlog.tasks in
        (match target_task with
        | None -> Error (Types.TaskNotFound task_id)
        | Some task ->
          if not (Agent_identity.role_satisfies
                    ~required:task.required_role ~agent_role) then
            Error (Types.TaskRoleMismatch {
              task_id;
              required = Agent_identity.role_to_string task.required_role;
              actual = Agent_identity.role_to_string agent_role;
            })
          else begin
            let found = ref false in
            let already_claimed = ref None in
            let new_tasks = List.map (fun t ->
              if t.id = task_id then begin
                found := true;
                match t.task_status with
                | Todo -> { t with task_status = Claimed { assignee = agent_name; claimed_at = now_iso () } }
                | Claimed { assignee; _ } | InProgress { assignee; _ } | Done { assignee; _ } | Cancelled { cancelled_by = assignee; _ } ->
                    already_claimed := Some assignee; t
              end else t
            ) backlog.tasks in
            if not !found then Error (Types.TaskNotFound task_id)
            else match !already_claimed with
              | Some other -> Error (Types.TaskAlreadyClaimed { task_id; by = other })
              | None ->
                  let new_backlog = {
                    tasks = new_tasks;
                    last_updated = now_iso ();
                    version = backlog.version + 1;
                  } in
                  write_backlog config new_backlog;
                  let agent_file = Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json") in
                  if Sys.file_exists agent_file then begin
                    let json = read_json config agent_file in
                    match agent_of_yojson json with
                    | Ok agent ->
                        let updated = { agent with status = Busy; current_task = Some task_id } in
                        write_json config agent_file (agent_to_yojson updated)
                    | Error msg ->
                        Log.Misc.error "agent state write failed: %s" msg
                  end;
                  let _ = broadcast config ~from_agent:agent_name ~content:(Printf.sprintf "📋 Claimed %s" task_id) in
                  log_event config (Yojson.Safe.to_string (`Assoc [("type", `String "task_claim"); ("agent", `String agent_name); ("task", `String task_id); ("ts", `String (now_iso ()))]));
                  Ok (Printf.sprintf "✅ %s claimed %s" agent_name task_id)
          end)
      with e -> Error (Types.IoError (Printexc.to_string e))
    )

(** Unified task transition (single entrypoint).
    When [~force:true], release/cancel/done bypass the assignee guard.
    Used by Board Gardener keeper for orphan task cleanup. *)
let transition_task_r config ~agent_name ~task_id ~action
    ?expected_version ?(notes="") ?(reason="") ?(force=false) () : string Types.masc_result =
  if not (is_initialized config) then Error Types.NotInitialized
  else match validate_agent_name_r agent_name, validate_task_id_r task_id with
    | Error e, _ -> Error e
    | _, Error e -> Error e
    | Ok _, Ok _ ->
        let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
        with_file_lock config backlog_path (fun () ->
          try
            let backlog = read_backlog config in
            (match expected_version with
             | Some v when backlog.version <> v ->
                 Error (Types.TaskInvalidState
                   (Printf.sprintf "Version mismatch (expected %d, got %d)" v backlog.version))
             | _ ->
                 let task_opt = List.find_opt (fun t -> t.id = task_id) backlog.tasks in
                 match task_opt with
                 | None -> Error (Types.TaskNotFound task_id)
                 | Some task ->
                     let now = now_iso () in
                     let action = String.lowercase_ascii action in
                     let status_to_string = function
                       | Types.Todo -> "todo"
                       | Types.Claimed _ -> "claimed"
                       | Types.InProgress _ -> "in_progress"
                       | Types.Done _ -> "done"
                       | Types.Cancelled _ -> "cancelled"
                     in
                     let transition =
                       match action, task.task_status with
                       | "claim", Types.Todo ->
                           Ok (Types.Claimed { assignee = agent_name; claimed_at = now }, Some task_id)
                       | "start", Types.Claimed { assignee; _ } when assignee = agent_name ->
                           Ok (Types.InProgress { assignee = agent_name; started_at = now }, Some task_id)
                       | "done", Types.Claimed { assignee; _ }
                       | "done", Types.InProgress { assignee; _ } when assignee = agent_name || force ->
                           Ok (Types.Done {
                             assignee = agent_name;
                             completed_at = now;
                             notes = if notes = "" then None else Some notes;
                           }, None)
                       | "cancel", Types.Todo ->
                           Ok (Types.Cancelled {
                             cancelled_by = agent_name;
                             cancelled_at = now;
                             reason = if reason = "" then None else Some reason;
                           }, None)
                       | "cancel", Types.Claimed { assignee; _ }
                       | "cancel", Types.InProgress { assignee; _ } when assignee = agent_name || force ->
                           Ok (Types.Cancelled {
                             cancelled_by = agent_name;
                             cancelled_at = now;
                             reason = if reason = "" then None else Some reason;
                           }, None)
                       | "release", Types.Claimed { assignee; _ }
                       | "release", Types.InProgress { assignee; _ } when assignee = agent_name || force ->
                           Ok (Types.Todo, None)
                       | _ ->
                           Error (Types.TaskInvalidState
                             (Printf.sprintf "Invalid transition: %s -> %s (%s)"
                               (status_to_string task.task_status) action task_id))
                     in
                     (match transition with
                      | Error e -> Error e
                      | Ok (new_status, set_current) ->
                          let new_tasks = List.map (fun t ->
                            if t.id = task_id then { t with task_status = new_status } else t
                          ) backlog.tasks in
                          let new_backlog = {
                            tasks = new_tasks;
                            last_updated = now_iso ();
                            version = backlog.version + 1;
                          } in
                          write_backlog config new_backlog;
                          let agent_file = Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json") in
                          if Sys.file_exists agent_file then begin
                            let json = read_json config agent_file in
                            match agent_of_yojson json with
                            | Ok agent ->
                                let updated =
                                  match set_current with
                                  | Some _ -> { agent with status = Busy; current_task = Some task_id }
                                  | None ->
                                      if agent.current_task = Some task_id then
                                        { agent with status = Active; current_task = None }
                                      else
                                        agent
                                in
                                write_json config agent_file (agent_to_yojson updated)
                            | Error msg ->
                                Log.Misc.error "agent state write failed: %s" msg
                          end;
                          log_event config (Printf.sprintf
                            "{\"type\":\"task_transition\",\"agent\":\"%s\",\"task\":\"%s\",\"action\":\"%s\",\"from\":\"%s\",\"to\":\"%s\",\"ts\":\"%s\"}"
                            agent_name task_id action
                            (status_to_string task.task_status)
                            (status_to_string new_status)
                            now);
                          Ok (Printf.sprintf "✅ %s %s → %s" task_id
                                (status_to_string task.task_status)
                                (status_to_string new_status))
                     ))
          with e -> Error (Types.IoError (Printexc.to_string e))
        )

(** Release task back to backlog - transition wrapper *)
let release_task_r config ~agent_name ~task_id ?expected_version () : string Types.masc_result =
  transition_task_r config ~agent_name ~task_id ~action:"release" ?expected_version ()

(** Force-release a task regardless of assignee. Board Gardener privilege. *)
let force_release_task_r config ~agent_name ~task_id () : string Types.masc_result =
  transition_task_r config ~agent_name ~task_id ~action:"release" ~force:true ()

(** Force-done a task regardless of assignee. Board Gardener privilege. *)
let force_done_task_r config ~agent_name ~task_id ~notes () : string Types.masc_result =
  transition_task_r config ~agent_name ~task_id ~action:"done" ~notes ~force:true ()

(** Complete task with file locking *)
let complete_task config ~agent_name ~task_id ~notes =
  ensure_initialized config;
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  with_file_lock config backlog_path (fun () ->
    try
      let backlog = read_backlog config in
      let task_opt = List.find_opt (fun t -> t.id = task_id) backlog.tasks in
      match task_opt with
      | None ->
          Printf.sprintf "❌ Task %s not found" task_id
      | Some task ->
          let can_complete = match task.task_status with
            | Claimed { assignee; _ } | InProgress { assignee; _ } -> assignee = agent_name
            | Todo | Done _ | Cancelled _ -> false
          in
          if not can_complete then
            Printf.sprintf "⚠ Task %s is not claimed by %s. Claim it first!" task_id agent_name
          else begin
            let new_tasks = List.map (fun t ->
              if t.id = task_id then
                { t with task_status = Done {
                    assignee = agent_name;
                    completed_at = now_iso ();
                    notes = if notes = "" then None else Some notes
                  }
                }
              else t
            ) backlog.tasks in
            let new_backlog = {
              tasks = new_tasks;
              last_updated = now_iso ();
              version = backlog.version + 1;
            } in
            write_backlog config new_backlog;
            let agent_file = Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json") in
            if Sys.file_exists agent_file then begin
              let json = read_json config agent_file in
              match agent_of_yojson json with
              | Ok agent ->
                  let updated = { agent with status = Active; current_task = None } in
                  write_json config agent_file (agent_to_yojson updated)
              | Error msg ->
                  Log.Misc.error "agent state write failed: %s" msg
            end;
            let msg = if notes = "" then Printf.sprintf "✅ Completed %s" task_id
                      else Printf.sprintf "✅ Completed %s - %s" task_id notes in
            let _ = broadcast config ~from_agent:agent_name ~content:msg in
            log_event config (Printf.sprintf
              "{\"type\":\"task_done\",\"agent\":\"%s\",\"task\":\"%s\",\"notes\":%s,\"ts\":\"%s\"}"
              agent_name task_id
              (if notes = "" then "null" else Printf.sprintf "\"%s\"" notes)
              (now_iso ()));
            Printf.sprintf "✅ %s completed %s" agent_name task_id
          end
    with e ->
      Printf.sprintf "❌ Error: %s" (Printexc.to_string e)
  )

(** Result-returning version of complete_task for type-safe error handling *)
let complete_task_r config ~agent_name ~task_id ~notes : string Types.masc_result =
  if not (is_initialized config) then Error Types.NotInitialized
  else
    let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
    with_file_lock config backlog_path (fun () ->
      try
        let backlog = read_backlog config in
        let task_opt = List.find_opt (fun t -> t.id = task_id) backlog.tasks in
        match task_opt with
        | None -> Error (Types.TaskNotFound task_id)
        | Some task ->
            let completion_error =
              match task.task_status with
              | Claimed { assignee; _ } | InProgress { assignee; _ } ->
                  if assignee = agent_name then
                    None
                  else
                    Some (Types.TaskAlreadyClaimed { task_id; by = assignee })
              | Todo -> Some (Types.TaskNotClaimed task_id)
              | Done { assignee; _ } ->
                  Some
                    (Types.TaskInvalidState
                       (Printf.sprintf
                          "task %s is already done by %s; inspect task history instead of calling masc_done again"
                          task_id assignee))
              | Cancelled { cancelled_by; _ } ->
                  Some
                    (Types.TaskInvalidState
                       (Printf.sprintf
                          "task %s was cancelled by %s; reopen or create a new task instead of calling masc_done"
                          task_id cancelled_by))
            in
            match completion_error with
            | Some err -> Error err
            | None -> begin
              let new_tasks = List.map (fun t ->
                if t.id = task_id then
                  { t with task_status = Done { assignee = agent_name; completed_at = now_iso (); notes = if notes = "" then None else Some notes } }
                else t
              ) backlog.tasks in
              let new_backlog = {
                tasks = new_tasks;
                last_updated = now_iso ();
                version = backlog.version + 1;
              } in
              write_backlog config new_backlog;
              let agent_file = Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json") in
              if Sys.file_exists agent_file then begin
                let json = read_json config agent_file in
                match agent_of_yojson json with
                | Ok agent -> let updated = { agent with status = Active; current_task = None } in write_json config agent_file (agent_to_yojson updated)
                | Error msg ->
                    Log.Misc.error "agent state write failed: %s" msg
              end;
              let msg = if notes = "" then Printf.sprintf "✅ Completed %s" task_id else Printf.sprintf "✅ Completed %s - %s" task_id notes in
              let _ = broadcast config ~from_agent:agent_name ~content:msg in
              log_event config (Yojson.Safe.to_string (`Assoc [("type", `String "task_done"); ("agent", `String agent_name); ("task", `String task_id); ("notes", if notes = "" then `Null else `String notes); ("ts", `String (now_iso ()))]));
              (* Agent Economy: earn credits for task completion *)
              (match Agent_economy.earn
                 ~base_path:config.base_path ~agent_name
                 ~kind:Earn_task_done ~reason:(Printf.sprintf "completed %s" task_id) () with
               | Ok _bal -> ()
               | Error msg ->
                 Log.Misc.error "task earn failed: %s" msg);
              Ok (Printf.sprintf "✅ %s completed %s" agent_name task_id)
            end
      with e -> Error (Types.IoError (Printexc.to_string e))
    )

(** Cancel a task - A2A compatible *)
let cancel_task_r config ~agent_name ~task_id ~reason : string Types.masc_result =
  if not (is_initialized config) then Error Types.NotInitialized
  else
    let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
    with_file_lock config backlog_path (fun () ->
      try
        let backlog = read_backlog config in
        let task_opt = List.find_opt (fun t -> t.id = task_id) backlog.tasks in
        match task_opt with
        | None -> Error (Types.TaskNotFound task_id)
        | Some task ->
            (* Can cancel if: Todo, Claimed by me, or InProgress by me *)
            let can_cancel = match task.task_status with
              | Types.Todo -> true
              | Types.Claimed { assignee; _ } | Types.InProgress { assignee; _ } -> assignee = agent_name
              | Types.Done _ | Types.Cancelled _ -> false
            in
            if not can_cancel then
              Error (Types.TaskInvalidState (Printf.sprintf "Cannot cancel task %s (already done/cancelled or owned by another agent)" task_id))
            else begin
              let new_tasks = List.map (fun t ->
                if t.id = task_id then
                  { t with task_status = Types.Cancelled {
                    cancelled_by = agent_name;
                    cancelled_at = now_iso ();
                    reason = if reason = "" then None else Some reason
                  }}
                else t
              ) backlog.tasks in
              let new_backlog = {
                tasks = new_tasks;
                last_updated = now_iso ();
                version = backlog.version + 1;
              } in
              write_backlog config new_backlog;
              (* Update agent status if they had this task *)
              let agent_file = Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json") in
              if Sys.file_exists agent_file then begin
                let json = read_json config agent_file in
                match agent_of_yojson json with
                | Ok agent when agent.current_task = Some task_id ->
                    let updated = { agent with status = Active; current_task = None } in
                    write_json config agent_file (agent_to_yojson updated)
                | _ -> ()
              end;
              let msg = if reason = "" then Printf.sprintf "🚫 Cancelled %s" task_id else Printf.sprintf "🚫 Cancelled %s - %s" task_id reason in
              let _ = broadcast config ~from_agent:agent_name ~content:msg in
              log_event config (Yojson.Safe.to_string (`Assoc [("type", `String "task_cancelled"); ("agent", `String agent_name); ("task", `String task_id); ("reason", if reason = "" then `Null else `String reason); ("ts", `String (now_iso ()))]));
              Ok (Printf.sprintf "🚫 %s cancelled %s" agent_name task_id)
            end
      with e -> Error (Types.IoError (Printexc.to_string e))
    )

(** Structured result for claim_next_r (avoids brittle string parsing). *)
type claim_next_result =
  | Claim_next_claimed of {
      task_id : string;
      title : string;
      priority : int;
      released_task_id : string option;  (** Previous task auto-released, if any *)
      message : string;
    }
  | Claim_next_no_unclaimed
  | Claim_next_no_eligible of { excluded_count : int }
  | Claim_next_error of string

(** Claim next highest priority unclaimed task.
    Optional [exclude_task_ids] prevents re-claiming known bad tasks in the same loop run. *)
let default_stale_threshold_days = 7

let claim_next_r config ~agent_name ?(exclude_task_ids=[]) ?(stale_threshold_days=default_stale_threshold_days) () =
  ensure_initialized config;

  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  with_file_lock config backlog_path (fun () ->
    try
      let backlog = read_backlog config in

      (* BUG-004: Detect and auto-release previous claim to prevent orphaned tasks.
         If this agent already holds a Claimed or InProgress task, release it
         back to Todo before proceeding. This prevents "claimed but orphaned"
         tasks that permanently block the backlog. *)
      let previous_claim = List.find_opt (fun (t : Types.task) ->
        match t.task_status with
        | Claimed { assignee; _ } | InProgress { assignee; _ } ->
            String.equal assignee agent_name
        | Todo | Done _ | Cancelled _ -> false
      ) backlog.tasks in
      let released_task_id, working_tasks = match previous_claim with
        | None -> None, backlog.tasks
        | Some prev ->
            log_event config (Printf.sprintf
              "{\"type\":\"task_claim_next_auto_release\",\"agent\":\"%s\",\"released_task\":\"%s\",\"ts\":\"%s\"}"
              agent_name prev.id (now_iso ()));
            let _ = broadcast config ~from_agent:agent_name
              ~content:(Printf.sprintf
                "⚠ Auto-released %s (was %s) before claiming next task"
                prev.id (Types.task_status_to_string prev.task_status)) in
            let updated = List.map (fun (t : Types.task) ->
              if String.equal t.id prev.id then { t with task_status = Todo }
              else t
            ) backlog.tasks in
            Some prev.id, updated
      in

      (* Starvation prevention: Calculate effective priority
         Tasks waiting >24h get priority boost (-1 per 24h, min 1) *)
      let now = Time_compat.now () in
      let parse_time iso =
        try
          (* Parse ISO 8601: 2026-01-05T12:30:00Z *)
          Scanf.sscanf iso "%d-%d-%dT%d:%d:%d"
            (fun y mo d h mi _ ->
              let tm = { Unix.tm_sec = 0; tm_min = mi; tm_hour = h;
                         tm_mday = d; tm_mon = mo - 1; tm_year = y - 1900;
                         tm_wday = 0; tm_yday = 0; tm_isdst = false } in
              Some (fst (Unix.mktime tm)))
        with Scanf.Scan_failure _ | Failure _ | End_of_file -> None
      in
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
      (* BUG-009: Auto-archive stale Todo tasks (>N days old) to prevent queue clogging *)
      let stale_cutoff = now -. (float_of_int stale_threshold_days *. 86400.0) in
      let stale, fresh_tasks = List.partition (fun (t : Types.task) ->
        match t.task_status with
        | Todo ->
          (match parse_time t.created_at with
           | Some created -> created < stale_cutoff
           | None -> false)
        | _ -> false
      ) sorted in
      if stale <> [] then begin
        let stale_ids = List.map (fun (t : Types.task) -> t.id) stale in
        let remaining = List.filter (fun (t : Types.task) ->
          not (List.mem t.id stale_ids)
        ) backlog.tasks in
        write_backlog config { backlog with tasks = remaining };
        log_event config (Printf.sprintf
          "{\"type\":\"stale_task_auto_archive\",\"count\":%d,\"threshold_days\":%d,\"ts\":\"%s\"}"
          (List.length stale) stale_threshold_days (now_iso ()));
        let _ = broadcast config ~from_agent:"system"
          ~content:(Printf.sprintf "📦 Auto-archived %d stale Todo task(s) (>%dd old)"
            (List.length stale) stale_threshold_days) in
        ()
      end;
      let unclaimed = List.filter (fun t ->
        match t.task_status with
        | Todo -> true
        | _ -> false
      ) fresh_tasks in
      (* Also exclude the just-released task: the agent is moving on,
         re-claiming the same task would be a no-op loop. *)
      let all_excluded = match released_task_id with
        | Some rid -> rid :: exclude_task_ids
        | None -> exclude_task_ids
      in
      let eligible = List.filter (fun t -> not (List.mem t.id all_excluded)) unclaimed in

      (* Helper: clear agent current_task and reset status after auto-release
         when no replacement task can be claimed. *)
      let clear_agent_state_after_release () =
        match released_task_id with
        | Some _ ->
            let agent_file = Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json") in
            if Sys.file_exists agent_file then begin
              let json = read_json config agent_file in
              match agent_of_yojson json with
              | Ok agent ->
                  let updated = { agent with status = Active; current_task = None } in
                  write_json config agent_file (agent_to_yojson updated)
              | Error msg ->
                  Log.Misc.error "agent state clear failed: %s" msg
            end
        | None -> ()
      in

      match unclaimed, eligible with
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
               write_backlog config new_backlog
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
               write_backlog config new_backlog
           | None -> ());
          clear_agent_state_after_release ();
          Claim_next_no_eligible { excluded_count = List.length exclude_task_ids }
      | _ :: _, task :: _ ->
          (* Claim this task *)
          let new_tasks = List.map (fun t ->
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

          (* Update agent status *)
          let agent_file = Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json") in
          if Sys.file_exists agent_file then begin
            let json = read_json config agent_file in
            match agent_of_yojson json with
            | Ok agent ->
                let updated = { agent with status = Busy; current_task = Some task.id } in
                write_json config agent_file (agent_to_yojson updated)
            | Error msg ->
                Log.Misc.error "agent state write failed: %s" msg
          end;

          let release_note = match released_task_id with
            | Some rid -> Printf.sprintf " (auto-released %s)" rid
            | None -> ""
          in
          let _ = broadcast config ~from_agent:agent_name
            ~content:(Printf.sprintf "📋 Auto-claimed [P%d] %s: %s%s"
              task.priority task.id task.title release_note) in

          log_event config (Printf.sprintf
            "{\"type\":\"task_claim_next\",\"agent\":\"%s\",\"task\":\"%s\",\"priority\":%d,\"ts\":\"%s\"}"
            agent_name task.id task.priority (now_iso ()));

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
    with e ->
      Claim_next_error (Printexc.to_string e)
  )

(** Claim next highest priority unclaimed task (legacy string API). *)
let claim_next config ~agent_name =
  match claim_next_r config ~agent_name () with
  | Claim_next_claimed { message; _ } -> message
  | Claim_next_no_unclaimed -> "📋 No unclaimed tasks available"
  | Claim_next_no_eligible _ -> "📋 No unclaimed tasks available"
  | Claim_next_error e -> Printf.sprintf "❌ Error: %s" e

