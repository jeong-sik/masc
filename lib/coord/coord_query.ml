(** Coord_query -- Task/agent/message query and listing functions.

    Read-only operations on room state: raw list retrieval, orphan auditing,
    message collection, agent-joined checks, and formatted listing. *)

open Types
include Coord_utils
include Coord_state

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
          !Coord_hooks.on_task_mutation_fn ();

          Printf.sprintf "✅ Task %s priority: P%d → P%d" task_id old_priority priority
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e ->
      Printf.sprintf "❌ Error: %s" (Printexc.to_string e)
  )

(** Get raw task list (for orchestrator).
    Requires initialization. *)
let get_tasks_raw config =
  ensure_initialized config;
  (read_backlog config).tasks

(** Like [get_tasks_raw] but returns [[]] when MASC is not
    initialized — safe for dashboard and display contexts.
    Replaces the former [get_tasks_raw_in_room]. *)
let get_tasks_safe config =
  if not (root_is_initialized config) then []
  else (read_backlog config).tasks

let safe_yield () =
  try Eio.Fiber.yield () with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ()

let take_first n xs =
  if n <= 0 then []
  else
    let rec loop acc remaining = function
      | [] -> List.rev acc
      | _ when remaining <= 0 -> List.rev acc
      | x :: rest -> loop (x :: acc) (remaining - 1) rest
    in
    loop [] n xs

let list_leaf_json_names config dir =
  list_dir config dir
  |> List.filter (fun name ->
         name <> ""
         && not (String.contains name '/')
         && Filename.check_suffix name ".json")

let load_agents_from_dir config dir ~include_inactive =
  list_leaf_json_names config dir
  |> List.filter_map (fun name ->
         safe_yield ();
         let path = Filename.concat dir name in
         let json = read_json config path in
         match agent_of_yojson json with
         | Ok agent when include_inactive || agent.status <> Types.Inactive ->
             Some agent
         | Ok _ | Error _ -> None)

(** Get raw agent list (for orchestrator).
    Includes inactive agents. Requires initialization. *)
let get_agents_raw config =
  ensure_initialized config;
  let agents_path = agents_dir config in
  load_agents_from_dir config agents_path ~include_inactive:true

(** Return active agents only.  Returns [[]] when MASC is not
    initialized — safe for dashboard and display contexts.
    Replaces the former [get_agents_raw_in_room]. *)
let get_active_agents config =
  if not (root_is_initialized config) then []
  else
    let agents_path = agents_dir config in
    load_agents_from_dir config agents_path ~include_inactive:false

(** Like [get_agents_raw] but returns [[]] when not initialized
    instead of raising.  Includes inactive agents.
    Useful for keeper backlog-triage enrollment. *)
let get_all_agents config =
  if not (root_is_initialized config) then []
  else
    let agents_path = agents_dir config in
    load_agents_from_dir config agents_path ~include_inactive:true

(** Audit tasks: find claimed/in_progress tasks whose assignees are not active agents.
    Matches assignees by exact name or agent-type prefix (e.g. "claude" matches "claude-xxx").
    Agents with Inactive status are excluded from the active set. *)
let audit_orphan_tasks config : (Types.task * string) list =
  if not (is_initialized config) then []
  else
    (* Read agent files from the same path that cleanup_zombies and join use *)
    let agents_path = agents_dir config in
    let active_names =
      load_agents_from_dir config agents_path ~include_inactive:false
      |> List.map (fun (agent : Types.agent) -> agent.name)
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
  match read_json_opt config path with
  | None -> false
  | Some json ->
      (match agent_of_yojson json with
       | Ok agent -> agent.status <> Inactive
       | Error _ -> false)

(** Check if an agent has joined the room *)
let is_agent_joined config ~agent_name =
  if not (root_is_initialized config) then false
  else
    let actual_name = resolve_agent_name config agent_name in
    let filename = safe_filename actual_name ^ ".json" in
    let agents_path = agents_dir config in
    let agent_path = Filename.concat agents_path filename in
    is_agent_active_at_path config agent_path

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

let select_recent_message_names ~since_seq ~limit names =
  let insert_candidate acc name =
    let seq = extract_seq_from_filename name in
    if limit <= 0 || seq <= since_seq then
      acc
    else
      let rec insert prefix = function
        | [] -> List.rev_append prefix [ (seq, name) ]
        | ((existing_seq, _) as existing) :: rest ->
            if seq >= existing_seq then
              List.rev_append prefix ((seq, name) :: existing :: rest)
            else
              insert (existing :: prefix) rest
      in
      insert [] acc |> take_first limit
  in
  names
  |> List.fold_left
       (fun acc name ->
         safe_yield ();
         insert_candidate acc name)
       []
  |> List.map snd

let select_all_message_names ~since_seq names =
  names
  |> List.filter_map (fun name ->
       let seq = extract_seq_from_filename name in
       if seq <= since_seq then None else Some (seq, name))
  |> List.sort (fun (seq_a, name_a) (seq_b, name_b) ->
       let cmp = compare seq_a seq_b in
       if cmp <> 0 then cmp else String.compare name_a name_b)
  |> List.map snd

(** Read most-recent messages without parsing the entire history directory. *)
let collect_recent_messages config ~msgs_path ~since_seq ~limit ~warn_label =
  if not (Sys.file_exists msgs_path) then []
  else
    let names =
      Sys.readdir msgs_path
      |> Array.to_list
      |> List.filter is_valid_filename
      |> select_recent_message_names ~since_seq ~limit
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
                Log.legacy_traceln ~level:Log.Warn ~module_name:"Coord"
                  (Printf.sprintf "[WARN] Failed to read %s %s: %s" warn_label
                     name (Printexc.to_string e));
                loop remaining acc rest
    in
    loop limit [] names

(** Get raw message list (for dashboard).
    Returns [[]] when MASC is not initialized. *)
let get_messages_raw config ~since_seq ~limit =
  if not (root_is_initialized config) then []
  else
    let msgs_path = messages_dir config in
    collect_recent_messages config ~msgs_path ~since_seq ~limit ~warn_label:"message"

let get_all_messages_raw config ~since_seq =
  if not (root_is_initialized config) then []
  else
    let msgs_path = messages_dir config in
    if not (Sys.file_exists msgs_path) then []
    else
      let names =
        Sys.readdir msgs_path
        |> Array.to_list
        |> List.filter is_valid_filename
        |> select_all_message_names ~since_seq
      in
      let rec loop acc = function
        | [] -> List.rev acc
        | name :: rest ->
            safe_yield ();
            let path = Filename.concat msgs_path name in
            match read_json config path with
            | json ->
                (match message_of_yojson json with
                 | Ok msg when msg.seq > since_seq -> loop (msg :: acc) rest
                 | _ -> loop acc rest)
            | exception (Eio.Cancel.Cancelled _ as e) -> raise e
            | exception e ->
                Log.legacy_traceln ~level:Log.Warn ~module_name:"Coord"
                  (Printf.sprintf
                     "[WARN] Failed to read room message %s: %s"
                     name (Printexc.to_string e));
                loop acc rest
      in
      loop [] names

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
      "📋 No tasks. ACTION: STOP calling keeper_tasks_list — the backlog is empty. Move on to other work or end your turn."
    else
      "📋 No active tasks (all done/cancelled). ACTION: STOP calling keeper_tasks_list — do not re-check. Move on to other work or end your turn."
  else begin
    let buf = Buffer.create 256 in
    Buffer.add_string buf "📋 Quest Board\n";
    Buffer.add_string buf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";

    let sorted = List.sort (fun a b -> compare a.priority b.priority) tasks in
    List.iter (fun task ->
      let status_icon = match task.task_status with
        | Done _ -> "✅"
        | Claimed _ | InProgress _ -> "🔄"
        | AwaitingVerification _ -> "🔍"
        | Todo -> "📋"
        | Cancelled _ -> "🚫"
      in
      let assignee = match task.task_status with
        | Claimed { assignee; _ } | InProgress { assignee; _ } | Done { assignee; _ }
        | AwaitingVerification { assignee; _ } -> assignee
        | Cancelled { cancelled_by; _ } -> cancelled_by
        | Todo -> "unclaimed"
      in
      let status_str = match task.task_status with
        | Todo -> "todo"
        | Claimed _ -> "claimed"
        | InProgress _ -> "in_progress"
        | AwaitingVerification _ -> "awaiting_verification"
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
  let messages = get_messages_raw config ~since_seq ~limit in
  List.iter
    (fun msg ->
      let time_part =
        String.sub msg.timestamp 0 (min 16 (String.length msg.timestamp))
      in
      let time_str = String.map (function 'T' -> ' ' | c -> c) time_part in
      Buffer.add_string buf
        (Printf.sprintf "[%s] %s: %s\n" time_str msg.from_agent msg.content))
    messages;

  if Buffer.length buf = 73 then (* Only header *)
    Buffer.add_string buf "(no new messages)\n";

  Buffer.contents buf
