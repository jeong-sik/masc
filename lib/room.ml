(** MASC Room - Core coordination logic *)

open Types

(* Include all utilities from Room_utils *)
include Room_utils

(* Include state management, backlog, broadcast, resolve, bootstrap, zombie helpers *)
include Room_state

(** Join room - now with auto-generated nickname and metadata *)
let join config ~agent_name ?(agent_type_override=None) ~capabilities
    ?(pid=None) ?(hostname=None) ?(tty=None) ?(worktree=None) ?(parent_task=None) () =
  ensure_initialized config;

  (* Determine if this is a legacy call (agent_name = type) or new style *)
  let agent_type = match agent_type_override with
    | Some t -> t
    | None ->
        (* Check if agent_name looks like a nickname (has dashes) *)
        if Nickname.is_generated_nickname agent_name then
          Option.value (Nickname.extract_agent_type agent_name) ~default:agent_name
        else
          agent_name  (* Legacy: agent_name is the type *)
  in

  (* Reuse existing nickname for same agent_type if already joined,
     otherwise generate a new one. This prevents identity drift when
     the same agent_name joins multiple times within a session. *)
  let nickname =
    if Nickname.is_generated_nickname agent_name then
      agent_name  (* Already a nickname, use as-is *)
    else begin
      let dir = agents_dir config in
      let prefix = safe_filename agent_type ^ "-" in
      let existing =
        if Sys.file_exists dir && Sys.is_directory dir then
          Array.to_list (Sys.readdir dir)
          |> List.find_opt (fun f ->
               Filename.check_suffix f ".json"
               && String.length f > String.length prefix
               && String.sub f 0 (String.length prefix) = prefix)
          |> Option.map (fun f -> Filename.chop_suffix f ".json")
        else None
      in
      match existing with
      | Some nick -> nick  (* Reuse existing nickname for this agent_type *)
      | None -> Nickname.generate agent_type
    end
  in

  (* Dedup: if agent already joined, update last_seen and return early *)
  let agent_file_dedup = Filename.concat (agents_dir config) (safe_filename nickname ^ ".json") in
  let already_joined =
    if is_pg_backend config then
      let agent_key = Printf.sprintf "agents:%s" (safe_filename nickname) in
      backend_exists config ~key:agent_key || Sys.file_exists agent_file_dedup
    else
      Sys.file_exists agent_file_dedup
  in
  if already_joined then begin
    let existing_json = read_json config agent_file_dedup in
    (match agent_of_yojson existing_json with
     | Ok existing_agent ->
       let is_inactive = existing_agent.status = Inactive in
       let new_session_id = if is_inactive then generate_session_id () else
         match existing_agent.meta with Some m -> m.session_id | None -> generate_session_id ()
       in
       let new_meta : agent_meta = {
         session_id = new_session_id;
         agent_type;
         pid;
         hostname = (match hostname with Some h -> Some h | None -> get_hostname ());
         tty = (match tty with Some t -> Some t | None -> get_tty ());
         worktree;
         parent_task;
       } in
       let updated = { existing_agent with
         status = Active;
         last_seen = now_iso ();
         capabilities;
         meta = Some new_meta;
       } in
       write_json config agent_file_dedup (agent_to_yojson updated);
       if is_pg_backend config then begin
         let agent_key = Printf.sprintf "agents:%s" (safe_filename nickname) in
         let _ = backend_set config ~key:agent_key
                   ~value:(Yojson.Safe.to_string (agent_to_yojson updated)) in ()
       end;
       if is_inactive then begin
         (* Restore to active_agents on rejoin *)
         let _ = update_state config (fun s ->
           let agents = nickname :: List.filter ((<>) nickname) s.active_agents in
           { s with active_agents = agents }
         ) in
         let _ = broadcast config ~from_agent:nickname
                   ~content:(Printf.sprintf "👋 %s rejoined the room" nickname) in
         log_event config (Printf.sprintf
           "{\"type\":\"agent_join\",\"agent\":\"%s\",\"agent_type\":\"%s\",\"session_id\":\"%s\",\"rejoin\":true,\"ts\":\"%s\"}"
           nickname agent_type new_session_id (now_iso ()))
       end
     | Error _ -> ());
    Printf.sprintf "✅ %s already in room (last_seen updated)" nickname
  end else begin
    (* Collect metadata *)
  let session_id = generate_session_id () in
  let meta : agent_meta = {
    session_id;
    agent_type;
    pid;
    hostname = (match hostname with Some h -> Some h | None -> get_hostname ());
    tty = (match tty with Some t -> Some t | None -> get_tty ());
    worktree;
    parent_task;
  } in

  let agent_file = Filename.concat (agents_dir config) (safe_filename nickname ^ ".json") in
  let agent = {
    name = nickname;
    agent_type;
    status = Active;
    capabilities;
    current_task = None;
    joined_at = now_iso ();
    last_seen = now_iso ();
    meta = Some meta;
  } in
  let agent_json = agent_to_yojson agent in
  (* Write to filesystem (for backward compatibility) *)
  write_json config agent_file agent_json;
  (* Also persist to PostgreSQL backend for HTTP state persistence (stateless requests) *)
  if is_pg_backend config then begin
    let agent_key = Printf.sprintf "agents:%s" (safe_filename nickname) in
    let _ = backend_set config ~key:agent_key ~value:(Yojson.Safe.to_string agent_json) in
    ()
  end;

  (* Update state *)
  let _ = update_state config (fun s ->
    let agents = nickname :: (List.filter ((<>) nickname) s.active_agents) in
    { s with active_agents = agents }
  ) in

  (* Broadcast join *)
  let _ = broadcast config ~from_agent:nickname ~content:(Printf.sprintf "👋 %s joined the room" nickname) in

  (* Log event with metadata *)
  log_event config (Printf.sprintf
    "{\"type\":\"agent_join\",\"agent\":\"%s\",\"agent_type\":\"%s\",\"session_id\":\"%s\",\"capabilities\":%s,\"ts\":\"%s\"}"
    nickname
    agent_type
    session_id
    (Yojson.Safe.to_string (`List (List.map (fun s -> `String s) capabilities)))
    (now_iso ()));

  Printf.sprintf "✅ %s joined\n  Nickname: %s\n  Type: %s\n  Session: %s"
    nickname nickname agent_type session_id
  end

(** @deprecated Use [join (with_scope config (Named room_id))] instead. *)
let join_in_room config ~room_id ~agent_name ?(agent_type_override=None) ~capabilities
    ?(pid=None) ?(hostname=None) ?(tty=None) ?(worktree=None) ?(parent_task=None) () =
  let scoped = with_scope config (Named room_id) in
  ensure_room_bootstrap scoped room_id;

  let agent_type = match agent_type_override with
    | Some t -> t
    | None ->
        if Nickname.is_generated_nickname agent_name then
          Option.value (Nickname.extract_agent_type agent_name) ~default:agent_name
        else
          agent_name
  in
  let nickname =
    if Nickname.is_generated_nickname agent_name then agent_name
    else
      let resolved = resolve_agent_name (with_scope config (Named room_id)) agent_name in
      if resolved <> agent_name && Nickname.is_generated_nickname resolved then
        resolved
      else
        Nickname.generate agent_type
  in
  let agent_file_dedup =
    Filename.concat (agents_dir scoped) (safe_filename nickname ^ ".json")
  in
  if Sys.file_exists agent_file_dedup then begin
    let existing_json = read_json scoped agent_file_dedup in
    (match agent_of_yojson existing_json with
     | Ok existing_agent ->
         let is_inactive = existing_agent.status = Inactive in
         let updated = { existing_agent with
           status = Active;
           last_seen = now_iso ();
           capabilities;
         } in
         write_json scoped agent_file_dedup (agent_to_yojson updated);
         if is_inactive then begin
           let _ = update_state scoped (fun s ->
             let agents = nickname :: List.filter ((<>) nickname) s.active_agents in
             { s with active_agents = agents }
           ) in
           let _ = broadcast scoped ~from_agent:nickname
                     ~content:(Printf.sprintf "👋 %s rejoined room %s" nickname room_id) in
           log_event scoped (Printf.sprintf
             "{\"type\":\"agent_join\",\"room_id\":\"%s\",\"agent\":\"%s\",\"rejoin\":true,\"ts\":\"%s\"}"
             room_id nickname (now_iso ()))
         end
     | Error _ -> ());
    Printf.sprintf "✅ %s already in room %s (last_seen updated)" nickname room_id
  end else begin
    let session_id = generate_session_id () in
    let meta : agent_meta = {
      session_id;
      agent_type;
      pid;
      hostname = (match hostname with Some h -> Some h | None -> get_hostname ());
      tty = (match tty with Some t -> Some t | None -> get_tty ());
      worktree;
      parent_task;
    } in
    let agent_file =
      Filename.concat (agents_dir scoped) (safe_filename nickname ^ ".json")
    in
    let agent = {
      name = nickname;
      agent_type;
      status = Active;
      capabilities;
      current_task = None;
      joined_at = now_iso ();
      last_seen = now_iso ();
      meta = Some meta;
    } in
    write_json scoped agent_file (agent_to_yojson agent);
    let _ = update_state scoped (fun s ->
      let agents = nickname :: List.filter ((<>) nickname) s.active_agents in
      { s with active_agents = agents }
    ) in
    let _ =
      broadcast scoped ~from_agent:nickname
        ~content:(Printf.sprintf "👋 %s joined the room" nickname)
    in
    log_event scoped (Printf.sprintf
      "{\"type\":\"agent_join\",\"room_id\":\"%s\",\"agent\":\"%s\",\"agent_type\":\"%s\",\"session_id\":\"%s\",\"capabilities\":%s,\"ts\":\"%s\"}"
      room_id
      nickname
      agent_type
      session_id
      (Yojson.Safe.to_string (`List (List.map (fun s -> `String s) capabilities)))
      (now_iso ()));
    Printf.sprintf "✅ %s joined room %s" nickname room_id
  end

(** Leave room *)
let leave config ~agent_name =
  ensure_initialized config;

  (* Support both exact nickname match and agent_type prefix match *)
  let actual_name = resolve_agent_name config agent_name in

  (* Stop any heartbeats owned by this agent *)
  let _stopped = Heartbeat.stop_by_agent ~agent_name:actual_name in

  let agent_file = Filename.concat (agents_dir config) (safe_filename actual_name ^ ".json") in
  let in_fs = Sys.file_exists agent_file in
  (* For PostgreSQL backend: also check masc_kv for HTTP state persistence *)
  let in_backend =
    if is_pg_backend config then
      let agent_key = Printf.sprintf "agents:%s" (safe_filename actual_name) in
      backend_exists config ~key:agent_key
    else
      false
  in
  if in_fs || in_backend then begin
    (* Mark agent as Inactive instead of deleting, so re-join can restore identity.
       This prevents orphan state when the same agent_type re-joins later. *)
    (if in_fs then
      let existing_json = read_json config agent_file in
      match agent_of_yojson existing_json with
      | Ok existing_agent ->
        let updated = { existing_agent with status = Inactive; last_seen = now_iso () } in
        write_json config agent_file (agent_to_yojson updated)
      | Error _ -> ());
    if is_pg_backend config then begin
      let agent_key = Printf.sprintf "agents:%s" (safe_filename actual_name) in
      (* Update backend entry to Inactive as well *)
      (if in_fs then
        let updated_json = read_json config agent_file in
        let _ = backend_set config ~key:agent_key
                  ~value:(Yojson.Safe.to_string updated_json) in ()
      else
        let _ = backend_delete config ~key:agent_key in ())
    end;

    (* Capture active agents before removal for relationship materialization *)
    let peers_before_leave = (read_state config).active_agents in

    let _ = update_state config (fun s ->
      { s with active_agents = List.filter ((<>) actual_name) s.active_agents }
    ) in

    let _ = broadcast config ~from_agent:"system" ~content:(Printf.sprintf "👋 %s left the room" actual_name) in

    (* Log event *)
    log_event config (Printf.sprintf
      "{\"type\":\"agent_leave\",\"agent\":\"%s\",\"ts\":\"%s\"}"
      actual_name (now_iso ()));

    (* Record co-presence relationships to Neo4j (async, non-blocking) *)
    (try Relation_materializer.on_agent_leave
           ~leaving_agent:actual_name ~active_agents:peers_before_leave
     with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
       Log.Room.error "relation-materializer leave hook error: %s"
         (Printexc.to_string exn));

    Printf.sprintf "✅ %s left the room" actual_name
  end else
    Printf.sprintf "⚠ %s was not in the room" actual_name

(* broadcast is in Room_state *)

(** Initialize MASC room *)
let init config ~agent_name =
  (* Ensure root .masc structure exists even when initializing a non-default room. *)
  let root_dir = masc_root_dir config in
  let root_agents_dir = Filename.concat root_dir "agents" in
  let root_tasks_dir = Filename.concat root_dir "tasks" in
  let root_messages_dir = Filename.concat root_dir "messages" in
  let root_backlog_path = Filename.concat root_tasks_dir "backlog.json" in
  List.iter mkdir_p [root_agents_dir; root_tasks_dir; root_messages_dir; rooms_root_dir config];
  if not (path_exists_root config (root_state_path config)) then begin
    let root_state = {
      protocol_version = "0.1.0";
      project = Filename.basename config.base_path;
      started_at = now_iso ();
      message_seq = 0;
      active_agents = [];
      paused = false;
      pause_reason = None;
      paused_by = None;
      paused_at = None;
      search_strategy_default = Some "best_first_v1";
      speculation_enabled = false;
      speculation_budget = None;
    } in
    write_json_root config (root_state_path config) (room_state_to_yojson root_state)
  end;
  if not (path_exists_root config root_backlog_path) then begin
    let root_backlog = { tasks = []; last_updated = now_iso (); version = 1 } in
    write_json_root config root_backlog_path (backlog_to_yojson root_backlog)
  end;

  if is_initialized config then
    "MASC already initialized."
  else begin
    (* Create directories *)
    List.iter mkdir_p [
      agents_dir config;
      tasks_dir config;
      messages_dir config;
    ];

    (* Create initial state *)
    let state = {
      protocol_version = "0.1.0";
      project = Filename.basename config.base_path;
      started_at = now_iso ();
      message_seq = 0;
      active_agents = [];
      paused = false;
      pause_reason = None;
      paused_by = None;
      paused_at = None;
      search_strategy_default = Some "best_first_v1";
      speculation_enabled = false;
      speculation_budget = None;
    } in
    write_state config state;

    (* Create empty backlog *)
    let backlog = { tasks = []; last_updated = now_iso (); version = 1 } in
    write_backlog config backlog;

    let result = "✅ MASC room created!" in

    (* Auto-join if agent specified *)
    match agent_name with
    | Some name -> result ^ "\n" ^ (join config ~agent_name:name ~capabilities:[] ())
    | None -> result
  end

(** Pause the room - stops orchestrator from spawning new agents *)
let pause config ~by ~reason =
  let _ = update_state config (fun s -> {
    s with
    paused = true;
    pause_reason = Some reason;
    paused_by = Some by;
    paused_at = Some (now_iso ());
  }) in
  (* Broadcast pause notification *)
  let _ = broadcast config ~from_agent:"system"
    ~content:(Printf.sprintf "⏸️ Room PAUSED by %s: %s" by reason) in
  ()

(** Resume the room *)
let resume config ~by =
  let state = read_state config in
  if not state.paused then
    `Already_running
  else begin
    let _ = update_state config (fun s -> {
      s with
      paused = false;
      pause_reason = None;
      paused_by = None;
      paused_at = None;
    }) in
    (* Broadcast resume notification *)
    let _ = broadcast config ~from_agent:"system"
      ~content:(Printf.sprintf "▶️ Room RESUMED by %s" by) in
    `Resumed
  end

(** Reset room - delete .masc/ folder *)
let reset config =
  if not (is_initialized config) then
    "⚠ MASC not initialized. Nothing to reset."
  else begin
    (* Recursive delete *)
    let rec rm_rf path =
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun name ->
          rm_rf (Filename.concat path name)
        );
        Unix.rmdir path
      end else
        Sys.remove path
    in
    rm_rf (masc_dir config);
    Printf.sprintf "🗑️ MASC room reset! (.masc/ deleted at %s)" config.base_path
  end

(* Zombie detection helpers (heartbeat_timeout_seconds, parse_iso_time,
   is_zombie_agent, take) are now in Room_state *)

(** Get room status *)
let status config =
  ensure_initialized config;

  let state = read_state config in
  let backlog = read_backlog config in
  let current_room = read_current_room config |> Option.value ~default:"default" in
  let max_agents_display = 40 in
  let max_active_tasks_display = 30 in

  let buf = Buffer.create 256 in
  let cluster_name =
    match config.backend_config.Backend.cluster_name with
    | "" -> state.project
    | name -> name
  in
  Buffer.add_string buf (Printf.sprintf "🏢 Cluster: %s\n" cluster_name);
  if cluster_name <> state.project then
    Buffer.add_string buf (Printf.sprintf "📦 Project: %s\n" state.project);
  Buffer.add_string buf (Printf.sprintf "📍 Room: %s\n" current_room);
  Buffer.add_string buf (Printf.sprintf "📁 Path: %s\n" config.base_path);
  Buffer.add_string buf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n";
  Buffer.add_string buf "📌 Players:\n";

  (* List agents (bounded for responsiveness) *)
  let agents_path = agents_dir config in
  if Sys.file_exists agents_path then begin
    let agents =
      Sys.readdir agents_path
      |> Array.to_list
      |> List.filter (fun name -> Filename.check_suffix name ".json")
      |> List.filter_map (fun name ->
          let path = Filename.concat agents_path name in
          let json = read_json config path in
          match agent_of_yojson json with
          | Ok agent ->
              let is_zombie = is_zombie_agent ~agent_name:agent.name agent.last_seen in
              let icon =
                if is_zombie then "💀"
                else
                  match agent.status with
                  | Busy -> "🔴"
                  | Active -> "🟢"
                  | Listening -> "🎧"
                  | Inactive -> "⚫"
              in
              let task =
                if is_zombie then "zombie"
                else Option.value agent.current_task ~default:"idle"
              in
              Some (agent.name, icon, task)
          | Error _ -> None)
      |> List.sort (fun (a, _, _) (b, _, _) -> String.compare a b)
    in
    let total_agents = List.length agents in
    let shown_agents = take max_agents_display agents in
    List.iter (fun (name, icon, task) ->
      Buffer.add_string buf (Printf.sprintf "  %s %s → %s\n" icon name task)
    ) shown_agents;
    if total_agents > max_agents_display then
      Buffer.add_string buf
        (Printf.sprintf
           "  … and %d more agents (use masc_who for full list)\n"
           (total_agents - max_agents_display))
  end;

  Buffer.add_string buf "\n📋 Quest Board:\n";

  let sorted_tasks = List.sort (fun a b -> compare a.priority b.priority) backlog.tasks in
  let active_tasks, done_count, cancelled_count =
    List.fold_left
      (fun (active, done_cnt, cancelled_cnt) task ->
        match task.task_status with
        | Done _ -> (active, done_cnt + 1, cancelled_cnt)
        | Cancelled _ -> (active, done_cnt, cancelled_cnt + 1)
        | _ -> (task :: active, done_cnt, cancelled_cnt))
      ([], 0, 0) sorted_tasks
  in
  let active_tasks = List.rev active_tasks in
  let shown_active_tasks = take max_active_tasks_display active_tasks in
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
    Buffer.add_string buf (Printf.sprintf "  %s %s: %s (%s)\n" status_icon task.id task.title assignee)
  ) shown_active_tasks;

  if active_tasks = [] then
    Buffer.add_string buf "  (no active tasks)\n";
  if List.length active_tasks > max_active_tasks_display then
    Buffer.add_string buf
      (Printf.sprintf
         "  … and %d more active tasks (use masc_tasks for full list)\n"
         (List.length active_tasks - max_active_tasks_display));
  Buffer.add_string buf
    (Printf.sprintf
       "  Summary: active=%d, done=%d, cancelled=%d, total=%d\n"
       (List.length active_tasks) done_count cancelled_count (List.length backlog.tasks));

  (* Message summary: use cumulative sequence to avoid heavy directory scans *)
  let total_messages = max 0 state.message_seq in
  if total_messages > 0 then begin
    Buffer.add_string buf (Printf.sprintf "\n💬 Messages: %d (cumulative)\n" total_messages);
    Buffer.add_string buf "   Use masc_messages for recent details\n"
  end else
    Buffer.add_string buf "\n💬 Messages: 0\n";

  Buffer.contents buf


(* Task lifecycle: add, claim, transition, complete, cancel, claim_next *)
include Room_task

(* Walph control system: state machine, loop, presets *)
include Room_walph

(* Task/agent/message query and listing *)
include Room_query

(* ============================================================ *)
(* Portal / A2A Protocol - Extracted to Room_portal module      *)
(* ============================================================ *)
include Room_portal

(* ============================================ *)
(* Git Worktree - Extracted to Room_worktree module *)
(* ============================================ *)
include Room_worktree

(* Portal and Worktree functions are now in their respective modules.
   See Room_portal and Room_worktree for implementations. *)

(* ============================================ *)
(* Heartbeat & GC - Extracted to Room_gc        *)
(* ============================================ *)
include Room_gc
(* Connect the force_release_task callback for zombie cleanup *)
let () = Room_gc.force_release_task_fn :=
  (fun config ~agent_name ~task_id () ->
    force_release_task_r config ~agent_name ~task_id ())

(** Get all agents with their status.
    Uses room-scoped path for consistency with get_agents_raw. *)

(* Agent status, capability registration, discovery *)
include Room_agent


(* ============================================ *)
(* Consensus / Voting - Extracted to Room_vote  *)
(* ============================================ *)
include Room_vote

(* ============================================ *)
(* Tempo Control (Cluster Pace Management)     *)
(* ============================================ *)

(** Path to tempo.json *)
let tempo_path config = Filename.concat (masc_dir config) "tempo.json"

(** Read tempo config from file *)
let read_tempo config : tempo_config =
  let path = tempo_path config in
  if Sys.file_exists path then
    try
      match tempo_config_of_yojson (read_json config path) with
      | Ok t -> t
      | Error _ -> default_tempo_config
    with Sys_error _ | Yojson.Json_error _ -> default_tempo_config
  else
    default_tempo_config

(** Write tempo config to file *)
let write_tempo config (tempo : tempo_config) =
  write_json config (tempo_path config) (tempo_config_to_yojson tempo)

(** Get current tempo - returns JSON for MCP response *)
let get_tempo config =
  ensure_initialized config;
  let tempo = read_tempo config in
  tempo_config_to_yojson tempo

(** Set tempo with mode, reason, and agent tracking *)
let set_tempo config ~mode ~reason ~agent_name =
  ensure_initialized config;
  match tempo_mode_of_string mode with
  | Error e -> Printf.sprintf "❌ Invalid tempo mode: %s" e
  | Ok tempo_mode ->
      (* Set delay based on mode *)
      let delay_ms = match tempo_mode with
        | Normal -> 0
        | Slow -> 2000    (* 2 second delay for careful work *)
        | Fast -> 0       (* No delay *)
        | Paused -> 0     (* No delay, but paused state *)
      in
      let tempo = {
        mode = tempo_mode;
        delay_ms;
        reason;
        set_by = Some agent_name;
        set_at = Some (now_iso ());
      } in
      write_tempo config tempo;

      (* Broadcast tempo change *)
      let emoji = match tempo_mode with
        | Normal -> "🎵"
        | Slow -> "🐢"
        | Fast -> "🚀"
        | Paused -> "⏸️"
      in
      let reason_str = match reason with
        | Some r -> Printf.sprintf " (%s)" r
        | None -> ""
      in
      let _ = broadcast config ~from_agent:agent_name
        ~content:(Printf.sprintf "%s Tempo → %s%s" emoji mode reason_str) in

      Printf.sprintf "✅ Tempo set to %s (delay: %dms)%s" mode delay_ms reason_str

(* ============================================ *)
(* Multi-Room Management                        *)
(* ============================================ *)

include Room_multi

(** List all available rooms *)
let rooms_list config : Yojson.Safe.t =
  if not (root_is_initialized config) then
    `Assoc [
      ("rooms", `List []);
      ("current_room", `Null);
      ("error", `String "MASC not initialized")
    ]
  else begin
    let registry = load_registry config in
    let current = read_current_room config in

    (* Always include default room even if not in registry *)
    let default_room : Types.room_info = {
      id = "default";
      name = "Default Room";
      description = Some "Default coordination room";
      created_at = now_iso ();  (* Current time instead of epoch *)
      created_by = None;
      agent_count = count_agents_in_room config "default";
      task_count = count_tasks_in_room config "default";
    } in

    (* Update room counts and merge with default *)
    let rooms_with_counts = List.map (fun (r : Types.room_info) ->
      { r with
        agent_count = count_agents_in_room config r.id;
        task_count = count_tasks_in_room config r.id;
      }
    ) registry.rooms in

    (* Ensure default is in the list *)
    let all_rooms =
      if List.exists (fun (r : Types.room_info) -> r.id = "default") rooms_with_counts then
        rooms_with_counts
      else
        default_room :: rooms_with_counts
    in

    `Assoc [
      ("rooms", `List (List.map Types.room_info_to_yojson all_rooms));
      ("current_room", match current with Some r -> `String r | None -> `String "default");
    ]
  end

(** Create a new room *)
let room_create config ~name ~description : Yojson.Safe.t =
  if not (root_is_initialized config) then
    `Assoc [("error", `String "MASC not initialized")]
  else begin
    let room_id = slugify name in

    (* Check if room already exists *)
    let registry = load_registry config in
    if List.exists (fun (r : Types.room_info) -> r.id = room_id) registry.rooms then
      `Assoc [("error", `String (Printf.sprintf "Room '%s' already exists" room_id))]
    else if room_id = "default" then
      `Assoc [("error", `String "Cannot create room with reserved name 'default'")]
    else begin
      (* Create room directory structure *)
      mkdir_p (rooms_dir config);
      let rpath = room_path config room_id in
      mkdir_p rpath;
      mkdir_p (Filename.concat rpath "agents");
      mkdir_p (Filename.concat rpath "tasks");
      mkdir_p (Filename.concat rpath "locks");

      (* Create room info *)
      let room_info : Types.room_info = {
        id = room_id;
        name;
        description;
        created_at = now_iso ();
        created_by = None;
        agent_count = 0;
        task_count = 0;
      } in

      (* Update registry *)
      let updated_registry = {
        registry with
        rooms = room_info :: registry.rooms;
      } in
      save_registry config updated_registry;

      `Assoc [
        ("id", `String room_id);
        ("name", `String name);
        ("message", `String (Printf.sprintf "✅ Room '%s' created" room_id));
      ]
    end
  end

(** Ensure room exists as an SSOT registry entry and directory skeleton. *)
let ensure_room_entry config room_id =
  if room_id = "default" || room_id = "" then
    ()
  else if not (root_is_initialized config) then
    ()
  else begin
    let registry = load_registry config in
    if List.exists (fun (r : Types.room_info) -> r.id = room_id) registry.rooms then
      ()
    else (
      mkdir_p (rooms_dir config);
      let rpath = room_path config room_id in
      mkdir_p rpath;
      mkdir_p (Filename.concat rpath "agents");
      mkdir_p (Filename.concat rpath "tasks");
      mkdir_p (Filename.concat rpath "locks");
      let room_info : Types.room_info = {
        id = room_id;
        name = room_id;
        description = None;
        created_at = now_iso ();
        created_by = None;
        agent_count = 0;
        task_count = 0;
      } in
      let updated_registry = {
        registry with
        rooms = room_info :: registry.rooms;
      } in
      save_registry config updated_registry
    )
  end

(** Enter a room (switch context) *)
let room_enter config ~room_id ?(agent_name="") ~agent_type () : Yojson.Safe.t =
  if not (root_is_initialized config) then
    `Assoc [("error", `String "MASC not initialized")]
  else begin
    (* Check if room exists *)
    let registry = load_registry config in
    let room_exists =
      room_id = "default" ||
      List.exists (fun (r : Types.room_info) -> r.id = room_id) registry.rooms
    in

    if not room_exists then
      `Assoc [("error", `String (Printf.sprintf "Room '%s' does not exist" room_id))]
    else begin
      let previous_room = read_current_room config in
      let trimmed_agent_name = String.trim agent_name in
      let effective_agent_name =
        if trimmed_agent_name <> "" then trimmed_agent_name else agent_type
      in

      (* If we have a concrete agent name, remove it from the previous room to avoid duplication. *)
      let should_auto_leave =
        trimmed_agent_name <> "" && is_agent_joined config ~agent_name:effective_agent_name
      in
      (match previous_room with
       | Some prev when prev <> room_id && should_auto_leave ->
           (try ignore (leave config ~agent_name:effective_agent_name)
            with e -> Log.Misc.error "room: auto-leave from %s failed: %s" prev (Printexc.to_string e))
       | _ -> ());

      (* Update current room file (for external tools) and create scoped config *)
      write_current_room config room_id;
      let target_scope = if room_id = "default" then Default else Named room_id in
      let scoped = with_scope config target_scope in

      (* Initialize the room on first entry (no auto-join). *)
      if not (is_initialized scoped) then
        (try ignore (init scoped ~agent_name:None)
         with e -> Log.Misc.error "room: init failed for %s: %s" room_id (Printexc.to_string e));

      (* Join the new room using scoped config *)
      let join_result = join scoped ~agent_name:effective_agent_name ~capabilities:[] () in

      (* Extract nickname from join result (format: "  Nickname: xxx\n...") *)
      let nickname =
        try
          let prefix = "  Nickname: " in
          let start_idx =
            let idx = ref 0 in
            while !idx < String.length join_result - String.length prefix &&
                  String.sub join_result !idx (String.length prefix) <> prefix do
              incr idx
            done;
            !idx + String.length prefix
          in
          let end_idx = String.index_from join_result start_idx '\n' in
          String.sub join_result start_idx (end_idx - start_idx)
        with Not_found | Invalid_argument _ -> agent_type ^ "-unknown"
      in

      `Assoc [
        ("previous_room", match previous_room with Some r -> `String r | None -> `Null);
        ("current_room", `String room_id);
        ("nickname", `String nickname);
        ("message", `String (Printf.sprintf "✅ Entered room '%s' as %s" room_id nickname));
      ]
    end
  end
