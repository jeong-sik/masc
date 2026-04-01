(** Room_task — Task lifecycle: add, claim, transition, complete, cancel, claim_next. *)

open Types
include Room_utils
include Room_state

let activity_room_id (config : Room_utils.config) =
  match config.scope with
  | Default -> "default"
  | Named id -> id

let emit_task_activity config ~agent_name ~task_id ~kind ~payload =
  try
    !Room_hooks.activity_emit_fn config
      ~room_id:(activity_room_id config)
      ~actor:Room_hooks.{ kind = "agent"; id = agent_name }
      ~subject:Room_hooks.{ kind = "task"; id = task_id }
      ~kind
      ~payload
      ~tags:[ "task"; kind ]
      ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Log.Misc.warn "task activity emit failed (%s %s): %s" kind task_id
        (Printexc.to_string exn)

let task_status_to_string = function
  | Types.Todo -> "todo"
  | Types.Claimed _ -> "claimed"
  | Types.InProgress _ -> "in_progress"
  | Types.Done _ -> "done"
  | Types.Cancelled _ -> "cancelled"

let task_started_at_unix status =
  let default_time = Time_compat.now () in
  match status with
  | Types.Claimed { claimed_at; _ } ->
      Types.parse_iso8601 ~default_time claimed_at
  | Types.InProgress { started_at; _ } ->
      Types.parse_iso8601 ~default_time started_at
  | _ -> default_time

let task_transition_details ~from_status ~to_status ?notes ?reason ?duration_ms
    ?(forced = false) () =
  let optional_field name = function
    | Some value -> [ (name, value) ]
    | None -> []
  in
  `Assoc
    ([
       ("from_status", `String (task_status_to_string from_status));
       ("to_status", `String (task_status_to_string to_status));
       ("forced", `Bool forced);
     ]
    @ optional_field "notes"
        (Option.map (fun value -> `String value) notes)
    @ optional_field "reason"
        (Option.map (fun value -> `String value) reason)
    @ optional_field "duration_ms"
        (Option.map (fun value -> `Int value) duration_ms))

let observe_task_transition config ~agent_name ~task_id ~transition ~details =
  !Room_hooks.observe_task_transition_fn config ~agent_name
    ~room_id:(activity_room_id config) ~task_id ~transition ~details

(** Add task — file-locked to prevent task ID collision under concurrency *)
let add_task config ~title ~priority ~description =
  ensure_initialized config;
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  with_file_lock config backlog_path (fun () ->
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
      required_role = Types_core.Unassigned;
      stage = None;
    } in

    let new_backlog = {
      tasks = backlog.tasks @ [new_task];
      last_updated = now_iso ();
      version = backlog.version + 1;
    } in
    write_backlog config new_backlog;
    emit_task_activity config ~agent_name:"system" ~task_id ~kind:"task.created"
      ~payload:
        (`Assoc
          [
            ("task_id", `String task_id);
            ("title", `String title);
            ("priority", `Int priority);
          ]);

    let _ = broadcast config ~from_agent:"system" ~content:(Printf.sprintf "📋 New quest: %s" title) in
    !Room_hooks.on_task_mutation_fn ();
    Printf.sprintf "✅ Added %s: %s" task_id title)

(** Add task with a required role constraint — file-locked *)
let add_task_with_role config ~title ~priority ~description ~required_role =
  ensure_initialized config;
  let backlog_path = Filename.concat (tasks_dir config) ".backlog" in
  with_file_lock config backlog_path (fun () ->
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
      stage = None;
    } in

    let new_backlog = {
      tasks = backlog.tasks @ [new_task];
      last_updated = now_iso ();
      version = backlog.version + 1;
    } in
    write_backlog config new_backlog;
    emit_task_activity config ~agent_name:"system" ~task_id ~kind:"task.created"
      ~payload:
        (`Assoc
          [
            ("task_id", `String task_id);
            ("title", `String title);
            ("priority", `Int priority);
            ( "required_role",
              `String (Types_core.role_to_string required_role) );
          ]);

    let role_str = Types_core.role_to_string required_role in
    let _ = broadcast config ~from_agent:"system"
      ~content:(Printf.sprintf "📋 New quest: %s (requires: %s)" title role_str) in
    Printf.sprintf "✅ Added %s: %s (required_role: %s)" task_id title role_str)

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
          required_role = Types_core.Unassigned; stage = None;
        }
      ) tasks in
      let new_backlog = {
        tasks = backlog.tasks @ added_tasks;
        last_updated = now_iso ();
        version = backlog.version + 1;
      } in
      write_backlog config new_backlog;
      List.iter
        (fun (task : Types.task) ->
          emit_task_activity config ~agent_name:"system" ~task_id:task.id
            ~kind:"task.created"
            ~payload:
              (`Assoc
                [
                  ("task_id", `String task.id);
                  ("title", `String task.title);
                  ("priority", `Int task.priority);
                ]))
        added_tasks;
      let summary = String.concat ", " (List.map (fun (t : Types.task) -> t.id) added_tasks) in
      let msg = Printf.sprintf "📋 New batch of %d quests added: %s" (List.length added_tasks) summary in
      let _ = broadcast config ~from_agent:"system" ~content:msg in
      !Room_hooks.on_task_mutation_fn ();
      Printf.sprintf "✅ Added %d tasks: %s" (List.length added_tasks) summary
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e ->
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
            emit_task_activity config ~agent_name ~task_id ~kind:"task.claimed"
              ~payload:(`Assoc [ ("task_id", `String task_id) ]);
            log_event config (Printf.sprintf
              "{\"type\":\"task_claim\",\"agent\":\"%s\",\"task\":\"%s\",\"ts\":\"%s\"}"
              agent_name task_id (now_iso ()));
            observe_task_transition config ~agent_name ~task_id
              ~transition:"claim"
              ~details:
                (task_transition_details ~from_status:Types.Todo
                   ~to_status:
                     (Types.Claimed
                        { assignee = agent_name; claimed_at = now_iso () })
                   ());
            Printf.sprintf "✅ %s claimed %s" agent_name task_id
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e ->
      Printf.sprintf "❌ Error: %s" (Printexc.to_string e)
  )

(** Result-returning version of claim_task for type-safe error handling.
    When [agent_role] is provided and the task has a [required_role],
    the claim is rejected if the roles do not match. *)
let claim_task_r config ~agent_name ~task_id
    ?(agent_role = Types_core.Unassigned) () : string Types.masc_result =
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
          if not (Types_core.role_satisfies
                    ~required:task.required_role ~agent_role) then
            Error (Types.TaskRoleMismatch {
              task_id;
              required = Types_core.role_to_string task.required_role;
              actual = Types_core.role_to_string agent_role;
            })
          else begin
            (* fold_left to find+transform in a single pass without mutable refs.
               Uses polymorphic variants for inline state tracking. *)
            let claim_state, new_tasks =
              List.fold_left (fun (state, acc) t ->
                if t.id = task_id then
                  match t.task_status with
                  | Todo ->
                      let t' = { t with task_status = Claimed { assignee = agent_name; claimed_at = now_iso () } } in
                      (`Claimed_ok, t' :: acc)
                  | Claimed { assignee; _ } | InProgress { assignee; _ }
                  | Done { assignee; _ } | Cancelled { cancelled_by = assignee; _ } ->
                      (`Claimed_by assignee, t :: acc)
                else
                  (state, t :: acc)
              ) (`Not_found, []) backlog.tasks
            in
            let new_tasks = List.rev new_tasks in
            match claim_state with
            | `Not_found -> Error (Types.TaskNotFound task_id)
            | `Claimed_by other -> Error (Types.TaskAlreadyClaimed { task_id; by = other })
            | `Claimed_ok ->
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
                  emit_task_activity config ~agent_name ~task_id ~kind:"task.claimed"
                    ~payload:(`Assoc [ ("task_id", `String task_id) ]);
                  log_event config (Yojson.Safe.to_string (`Assoc [("type", `String "task_claim"); ("agent", `String agent_name); ("task", `String task_id); ("ts", `String (now_iso ()))]));
                  observe_task_transition config ~agent_name ~task_id
                    ~transition:"claim"
                    ~details:
                      (task_transition_details ~from_status:Types.Todo
                         ~to_status:
                           (Types.Claimed
                              {
                                assignee = agent_name;
                                claimed_at = now_iso ();
                              })
                         ());
                  Ok (Printf.sprintf "✅ %s claimed %s" agent_name task_id)
          end)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | e -> Error (Types.IoError (Printexc.to_string e))
    )

(** Unified task transition (single entrypoint).
    When [~force:true], release/cancel/done bypass the assignee guard.
    Used by keeper for orphan task cleanup. *)
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
                     let now_ts = Time_compat.now () in
                     let action = String.lowercase_ascii action in
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
                               (task_status_to_string task.task_status) action task_id))
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
                            (task_status_to_string task.task_status)
                            (task_status_to_string new_status)
                            now);
                          (match action with
                           | "claim" ->
                               emit_task_activity config ~agent_name ~task_id
                                 ~kind:"task.claimed"
                                 ~payload:(`Assoc [ ("task_id", `String task_id) ])
                           | "start" ->
                               emit_task_activity config ~agent_name ~task_id
                                 ~kind:"task.started"
                                 ~payload:(`Assoc [ ("task_id", `String task_id) ])
                           | "done" ->
                               emit_task_activity config ~agent_name ~task_id
                                 ~kind:"task.done"
                                 ~payload:
                                   (`Assoc
                                     [
                                       ("task_id", `String task_id);
                                       ("notes", if notes = "" then `Null else `String notes);
                                     ])
                           | "cancel" ->
                               emit_task_activity config ~agent_name ~task_id
                                 ~kind:"task.cancelled"
                                 ~payload:
                                   (`Assoc
                                     [
                                       ("task_id", `String task_id);
                                       ("reason", if reason = "" then `Null else `String reason);
                                     ])
                           | "release" ->
                               emit_task_activity config ~agent_name ~task_id
                                 ~kind:"task.released"
                                 ~payload:(`Assoc [ ("task_id", `String task_id) ])
                           | _ -> ());
                          let duration_ms =
                            match action with
                            | "done" | "cancel" ->
                                Some
                                  (max 0
                                     (int_of_float
                                        ((now_ts
                                         -. task_started_at_unix task.task_status)
                                        *. 1000.0)))
                            | _ -> None
                          in
                          observe_task_transition config ~agent_name ~task_id
                            ~transition:action
                            ~details:
                              (task_transition_details
                                 ~from_status:task.task_status ~to_status:new_status
                                 ?notes:(if notes = "" then None else Some notes)
                                 ?reason:(if reason = "" then None else Some reason)
                                 ?duration_ms ~forced:force ());
                          Ok (Printf.sprintf "✅ %s %s → %s" task_id
                                (task_status_to_string task.task_status)
                                (task_status_to_string new_status))
                     ))
          with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | e -> Error (Types.IoError (Printexc.to_string e))
        )

(** Release task back to backlog - transition wrapper *)
let release_task_r config ~agent_name ~task_id ?expected_version () : string Types.masc_result =
  transition_task_r config ~agent_name ~task_id ~action:"release" ?expected_version ()

(** Force-release a task regardless of assignee. Keeper privilege. *)
let force_release_task_r config ~agent_name ~task_id () : string Types.masc_result =
  transition_task_r config ~agent_name ~task_id ~action:"release" ~force:true ()

(** Force-done a task regardless of assignee. Keeper privilege. *)
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
            emit_task_activity config ~agent_name ~task_id ~kind:"task.done"
              ~payload:
                (`Assoc
                  [
                    ("task_id", `String task_id);
                    ("notes", if notes = "" then `Null else `String notes);
                  ]);
            log_event config (Printf.sprintf
              "{\"type\":\"task_done\",\"agent\":\"%s\",\"task\":\"%s\",\"notes\":%s,\"ts\":\"%s\"}"
              agent_name task_id
              (if notes = "" then "null" else Printf.sprintf "\"%s\"" notes)
              (now_iso ()));
            observe_task_transition config ~agent_name ~task_id
              ~transition:"done"
              ~details:
                (task_transition_details ~from_status:task.task_status
                   ~to_status:
                     (Types.Done
                        {
                          assignee = agent_name;
                          completed_at = now_iso ();
                          notes = if notes = "" then None else Some notes;
                        })
                   ?notes:(if notes = "" then None else Some notes)
                   ~duration_ms:
                     (max 0
                        (int_of_float
                           ((Time_compat.now ()
                            -. task_started_at_unix task.task_status)
                           *. 1000.0)))
                   ());
            (* Record task collaboration via hook (async, non-blocking) *)
            (try
               let active = (Room_state.read_state config).active_agents in
               !Room_hooks.relation_on_task_done_fn ~assignee:agent_name ~active_agents:active
             with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
               Log.RoomTask.error "relation-materializer task hook error: %s"
                 (Printexc.to_string exn));
            Printf.sprintf "✅ %s completed %s" agent_name task_id
          end
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e ->
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
              emit_task_activity config ~agent_name ~task_id ~kind:"task.done"
                ~payload:
                  (`Assoc
                    [
                      ("task_id", `String task_id);
                      ("notes", if notes = "" then `Null else `String notes);
                    ]);
              log_event config (Yojson.Safe.to_string (`Assoc [("type", `String "task_done"); ("agent", `String agent_name); ("task", `String task_id); ("notes", if notes = "" then `Null else `String notes); ("ts", `String (now_iso ()))]));
              observe_task_transition config ~agent_name ~task_id
                ~transition:"done"
                ~details:
                  (task_transition_details ~from_status:task.task_status
                     ~to_status:
                       (Types.Done
                          {
                            assignee = agent_name;
                            completed_at = now_iso ();
                            notes = if notes = "" then None else Some notes;
                          })
                     ?notes:(if notes = "" then None else Some notes)
                     ~duration_ms:
                       (max 0
                          (int_of_float
                             ((Time_compat.now ()
                              -. task_started_at_unix task.task_status)
                             *. 1000.0)))
                     ());
              (* Agent Economy: earn credits via hook *)
              !Room_hooks.agent_economy_earn_fn
                ~base_path:config.base_path ~agent_name
                ~reason:(Printf.sprintf "completed %s" task_id);
              Ok (Printf.sprintf "✅ %s completed %s" agent_name task_id)
            end
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | e -> Error (Types.IoError (Printexc.to_string e))
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
              emit_task_activity config ~agent_name ~task_id
                ~kind:"task.cancelled"
                ~payload:
                  (`Assoc
                    [
                      ("task_id", `String task_id);
                      ("reason", if reason = "" then `Null else `String reason);
                    ]);
              log_event config (Yojson.Safe.to_string (`Assoc [("type", `String "task_cancelled"); ("agent", `String agent_name); ("task", `String task_id); ("reason", if reason = "" then `Null else `String reason); ("ts", `String (now_iso ()))]));
              observe_task_transition config ~agent_name ~task_id
                ~transition:"cancel"
                ~details:
                  (task_transition_details ~from_status:task.task_status
                     ~to_status:
                       (Types.Cancelled
                          {
                            cancelled_by = agent_name;
                            cancelled_at = now_iso ();
                            reason = if reason = "" then None else Some reason;
                          })
                     ?reason:(if reason = "" then None else Some reason)
                     ~duration_ms:
                       (max 0
                          (int_of_float
                             ((Time_compat.now ()
                              -. task_started_at_unix task.task_status)
                             *. 1000.0)))
                     ());
              Ok (Printf.sprintf "🚫 %s cancelled %s" agent_name task_id)
            end
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | e -> Error (Types.IoError (Printexc.to_string e))
    )

(* Scheduling functions are in Room_task_schedule.
   Re-export claim_next_result from Types for backward compatibility. *)
type claim_next_result = Types.claim_next_result =
  | Claim_next_claimed of {
      task_id : string;
      title : string;
      priority : int;
      released_task_id : string option;
      message : string;
    }
  | Claim_next_no_unclaimed
  | Claim_next_no_eligible of { excluded_count : int }
  | Claim_next_error of string
