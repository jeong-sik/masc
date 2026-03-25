(** Room_query -- Task/agent/message query and listing functions.

    Read-only operations on room state: raw list retrieval, orphan auditing,
    message collection, agent-joined checks, and formatted listing. *)

open Types
include Room_utils
include Room_state

let update_priority config ~task_id ~priority =
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
          let old_priority = task.priority in
          let new_tasks = List.map (fun t ->
            if t.id = task_id then { t with priority }
            else t
          ) backlog.tasks in

          let new_backlog = {
            tasks = new_tasks;
            last_updated = now_iso ();
            version = backlog.version + 1;
          } in
          write_backlog config new_backlog;

          log_event config (Printf.sprintf
            "{\"type\":\"priority_change\",\"task\":\"%s\",\"old\":%d,\"new\":%d,\"ts\":\"%s\"}"
            task_id old_priority priority (now_iso ()));

          Printf.sprintf "✅ Task %s priority: P%d → P%d" task_id old_priority priority
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e ->
      Printf.sprintf "❌ Error: %s" (Printexc.to_string e)
  )

(** Get raw task list (for orchestrator) *)
let get_tasks_raw config =
  ensure_initialized config;
  read_backlog_in_room config (current_room_id config) |> fun backlog -> backlog.tasks

let get_tasks_raw_in_room config room_id =
  if not (root_is_initialized config) then []
  else
    let backlog = read_backlog_in_room config room_id in
    backlog.tasks

let safe_yield () =
  try Eio.Fiber.yield () with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ()

(** Get raw agent list (for orchestrator) *)
let get_agents_raw config =
  ensure_initialized config;
  let agents_path = agents_dir (with_scope config (Named (current_room_id config))) in
  if not (Sys.file_exists agents_path) then []
  else
    Sys.readdir agents_path
    |> Array.to_list
    |> List.filter (fun name -> Filename.check_suffix name ".json")
    |> List.filter_map (fun name ->
        safe_yield ();
        let path = Filename.concat agents_path name in
        let json = read_json config path in
        match agent_of_yojson json with
        | Ok agent -> Some agent
        | Error _ -> None
      )

let get_agents_raw_in_room config room_id =
  if not (root_is_initialized config) then []
  else
    let agents_path = agents_dir (with_scope config (Named room_id)) in
    if not (Sys.file_exists agents_path) then []
    else
      Sys.readdir agents_path
      |> Array.to_list
      |> List.filter (fun name -> Filename.check_suffix name ".json")
      |> List.filter_map (fun name ->
          safe_yield ();
          let path = Filename.concat agents_path name in
          let json = read_json config path in
          match agent_of_yojson json with
          | Ok agent when agent.status <> Types.Inactive -> Some agent
          | Ok _ | Error _ -> None
        )

(** Like [get_agents_raw_in_room] but includes Inactive agents.
    Useful for keeper backlog-triage enrollment where inactive agents
    should still participate as a fallback. *)
let get_all_agents_in_room config room_id =
  if not (root_is_initialized config) then []
  else
    let agents_path = agents_dir (with_scope config (Named room_id)) in
    if not (Sys.file_exists agents_path) then []
    else
      Sys.readdir agents_path
      |> Array.to_list
      |> List.filter (fun name -> Filename.check_suffix name ".json")
      |> List.filter_map (fun name ->
          safe_yield ();
          let path = Filename.concat agents_path name in
          let json = read_json config path in
          match agent_of_yojson json with
          | Ok agent -> Some agent
          | Error _ -> None
        )

(** Audit tasks: find claimed/in_progress tasks whose assignees are not active agents.
    Matches assignees by exact name or agent-type prefix (e.g. "claude" matches "claude-xxx").
    Agents with Inactive status are excluded from the active set. *)
let audit_orphan_tasks config : (Types.task * string) list =
  if not (is_initialized config) then []
  else
    (* Read agent files from the same path that cleanup_zombies and join use *)
    let agents_path = agents_dir config in
    let active_names =
      if Sys.file_exists agents_path then
        Sys.readdir agents_path
        |> Array.to_list
        |> List.filter (fun name -> Filename.check_suffix name ".json")
        |> List.filter_map (fun name ->
            safe_yield ();
            let path = Filename.concat agents_path name in
            let json = read_json config path in
            match agent_of_yojson json with
            | Ok agent when agent.status <> Types.Inactive -> Some agent.name
            | Ok _ | Error _ -> None)
      else []
    in
    let is_active_agent assignee =
      List.mem assignee active_names
      || let prefix = assignee ^ "-" in
         List.exists (fun name ->
           String.length name > String.length prefix
           && String.sub name 0 (String.length prefix) = prefix
         ) active_names
    in
    let backlog = read_backlog config in
    List.filter_map (fun (task : Types.task) ->
      match task.task_status with
      | Types.Claimed { assignee; _ }
      | Types.InProgress { assignee; _ } ->
          if is_active_agent assignee then None
          else Some (task, assignee)
      | _ -> None
    ) backlog.tasks

let is_agent_active_at_path config path =
  if not (path_exists config path) then false
  else
    try
      let json = read_json config path in
      match agent_of_yojson json with
      | Ok agent -> agent.status <> Inactive
      | Error _ -> false
    with Sys_error _ | Yojson.Json_error _ -> false

let is_agent_joined_in_room config ~room_id ~agent_name =
  if not (root_is_initialized config) then false
  else
    let actual_name = resolve_agent_name (with_scope config (Named room_id)) agent_name in
    let filename = safe_filename actual_name ^ ".json" in
    (* Check room-scoped path first *)
    let room_agents = agents_dir (with_scope config (Named room_id)) in
    let room_path = Filename.concat room_agents filename in
    if is_agent_active_at_path config room_path then true
    else
      (* Fallback: check root agents_dir (where default join writes) *)
      let root_agents = agents_dir config in
      let root_path = Filename.concat root_agents filename in
      is_agent_active_at_path config root_path

(** Check if an agent has joined the room *)
let is_agent_joined config ~agent_name =
  ensure_initialized config;
  is_agent_joined_in_room config ~room_id:(current_room_id config) ~agent_name

(** Check if filename is valid (no special characters) *)
let is_valid_filename name =
  String.for_all (fun c ->
    (c >= 'a' && c <= 'z') ||
    (c >= 'A' && c <= 'Z') ||
    (c >= '0' && c <= '9') ||
    c = '_' || c = '-' || c = '.'
  ) name

(** Extract seq number from filename like "000001885_unknown_broadcast.json" or "1664_codex_broadcast.json" *)
let extract_seq_from_filename name =
  match String.index_opt name '_' with
  | None -> 0
  | Some idx -> Safe_ops.int_of_string_with_default ~default:0 (String.sub name 0 idx)

(** Read most-recent messages without parsing the entire history directory. *)
let collect_recent_messages config ~msgs_path ~since_seq ~limit ~warn_label =
  let names =
    Sys.readdir msgs_path
    |> Array.to_list
    |> List.filter is_valid_filename
    |> List.sort (fun a b -> compare (extract_seq_from_filename b) (extract_seq_from_filename a))
  in
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | name :: rest ->
        safe_yield ();
        if extract_seq_from_filename name <= since_seq then List.rev acc
        else
          let path = Filename.concat msgs_path name in
          match read_json config path with
          | json ->
              (match message_of_yojson json with
               | Ok msg when msg.seq > since_seq -> loop (remaining - 1) (msg :: acc) rest
               | _ -> loop remaining acc rest)
          | exception (Eio.Cancel.Cancelled _ as e) -> raise e
          | exception e ->
              Log.legacy_traceln ~level:Log.Warn ~module_name:"Room"
                (Printf.sprintf "[WARN] Failed to read %s %s: %s" warn_label
                   name (Printexc.to_string e));
              loop remaining acc rest
  in
  loop limit [] names

(** Get raw message list (for dashboard) *)
let get_messages_raw config ~since_seq ~limit =
  ensure_initialized config;
  let msgs_path = messages_dir_in_room config (current_room_id config) in
  if not (Sys.file_exists msgs_path) then []
  else collect_recent_messages config ~msgs_path ~since_seq ~limit ~warn_label:"message"

let get_messages_raw_in_room config ~room_id ~since_seq ~limit =
  if not (root_is_initialized config) then []
  else
    let msgs_path = messages_dir_in_room config room_id in
    if not (Sys.file_exists msgs_path) then []
    else collect_recent_messages config ~msgs_path ~since_seq ~limit ~warn_label:"room message"

(** List tasks *)
let list_tasks ?(include_done = false) ?(include_cancelled = false) ?status config =
  ensure_initialized config;

  let backlog = read_backlog config in
  let tasks =
    match status with
    | Some status_filter ->
        List.filter (fun (task : task) ->
          String.equal status_filter (string_of_task_status task.task_status)
        ) backlog.tasks
    | None ->
        List.filter (fun (task : task) ->
          let is_done = match task.task_status with
            | Done _ -> true
            | _ -> false
          in
          let is_cancelled = match task.task_status with
            | Cancelled _ -> true
            | _ -> false
          in
          (include_done || not is_done) &&
          (include_cancelled || not is_cancelled)
        ) backlog.tasks
  in
  if tasks = [] then
    if backlog.tasks = [] then
      "📋 No tasks yet."
    else
      "📋 No active tasks. (use include_done=true or include_cancelled=true)"
  else begin
    let buf = Buffer.create 256 in
    Buffer.add_string buf "📋 Quest Board\n";
    Buffer.add_string buf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";

    let sorted = List.sort (fun a b -> compare a.priority b.priority) tasks in
    List.iter (fun task ->
      let status_icon = match task.task_status with
        | Done _ -> "✅"
        | Claimed _ | InProgress _ -> "🔄"
        | Todo -> "📋"
        | Cancelled _ -> "🚫"
      in
      let assignee = match task.task_status with
        | Claimed { assignee; _ } | InProgress { assignee; _ } | Done { assignee; _ } -> assignee
        | Cancelled { cancelled_by; _ } -> cancelled_by
        | Todo -> "unclaimed"
      in
      let status_str = match task.task_status with
        | Todo -> "todo"
        | Claimed _ -> "claimed"
        | InProgress _ -> "in_progress"
        | Done _ -> "done"
        | Cancelled _ -> "cancelled"
      in
      Buffer.add_string buf (Printf.sprintf "%s [%d] %s: %s\n" status_icon task.priority task.id task.title);
      Buffer.add_string buf (Printf.sprintf "   └─ %s | %s\n" status_str assignee)
    ) sorted;

    Buffer.contents buf
  end

(** Get recent messages *)
let get_messages config ~since_seq ~limit =
  ensure_initialized config;

  let buf = Buffer.create 256 in
  Buffer.add_string buf "💬 Recent Messages\n";
  Buffer.add_string buf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";

  let msgs_path = messages_dir config in
  if Sys.file_exists msgs_path then begin
    let files = Sys.readdir msgs_path |> Array.to_list
      |> List.sort (fun a b -> compare (extract_seq_from_filename b) (extract_seq_from_filename a)) in
    let count = ref 0 in
    List.iter (fun name ->
      if !count < limit then begin
        let path = Filename.concat msgs_path name in
        let json = read_json config path in
        match message_of_yojson json with
        | Ok msg when msg.seq > since_seq ->
            let time_part = String.sub msg.timestamp 0 (min 16 (String.length msg.timestamp)) in
            let time_str = String.map (function 'T' -> ' ' | c -> c) time_part in
            Buffer.add_string buf (Printf.sprintf "[%s] %s: %s\n" time_str msg.from_agent msg.content);
            incr count
        | _ -> ()
      end
    ) files
  end;

  if Buffer.length buf = 73 then (* Only header *)
    Buffer.add_string buf "(no new messages)\n";

  Buffer.contents buf
