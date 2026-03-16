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

  (* Generate unique nickname if agent_name is just a type *)
  let nickname =
    if Nickname.is_generated_nickname agent_name then
      agent_name  (* Already a nickname, use as-is *)
    else
      Nickname.generate agent_type  (* Generate new nickname *)
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
       let updated = { existing_agent with last_seen = now_iso () } in
       write_json config agent_file_dedup (agent_to_yojson updated);
       if is_pg_backend config then begin
         let agent_key = Printf.sprintf "agents:%s" (safe_filename nickname) in
         let _ = backend_set config ~key:agent_key
                   ~value:(Yojson.Safe.to_string (agent_to_yojson updated)) in ()
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

let join_in_room config ~room_id ~agent_name ?(agent_type_override=None) ~capabilities
    ?(pid=None) ?(hostname=None) ?(tty=None) ?(worktree=None) ?(parent_task=None) () =
  ensure_room_bootstrap config room_id;

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
    else Nickname.generate agent_type
  in
  let agent_file_dedup =
    Filename.concat (agents_dir_in_room config room_id) (safe_filename nickname ^ ".json")
  in
  if Sys.file_exists agent_file_dedup then begin
    let existing_json = read_json config agent_file_dedup in
    (match agent_of_yojson existing_json with
     | Ok existing_agent ->
         let updated = { existing_agent with last_seen = now_iso () } in
         write_json config agent_file_dedup (agent_to_yojson updated)
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
      Filename.concat (agents_dir_in_room config room_id) (safe_filename nickname ^ ".json")
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
    write_json config agent_file (agent_to_yojson agent);
    let _ = update_state_in_room config room_id (fun s ->
      let agents = nickname :: List.filter ((<>) nickname) s.active_agents in
      { s with active_agents = agents }
    ) in
    let _ =
      broadcast_in_room config ~room_id ~from_agent:nickname
        ~content:(Printf.sprintf "👋 %s joined the room" nickname)
    in
    log_event config (Printf.sprintf
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
    (* Remove from filesystem if exists *)
    if in_fs then Sys.remove agent_file;
    (* Remove from PostgreSQL backend if applicable *)
    if is_pg_backend config then begin
      let agent_key = Printf.sprintf "agents:%s" (safe_filename actual_name) in
      let _ = backend_delete config ~key:agent_key in
      ()
    end;

    let _ = update_state config (fun s ->
      { s with active_agents = List.filter ((<>) actual_name) s.active_agents }
    ) in

    let _ = broadcast config ~from_agent:"system" ~content:(Printf.sprintf "👋 %s left the room" actual_name) in

    (* Log event *)
    log_event config (Printf.sprintf
      "{\"type\":\"agent_leave\",\"agent\":\"%s\",\"ts\":\"%s\"}"
      actual_name (now_iso ()));

    Printf.sprintf "✅ %s left the room" actual_name
  end else
    Printf.sprintf "⚠ %s was not in the room" actual_name

(* broadcast and broadcast_in_room are now in Room_state *)

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


(* ======== Walph Control System ======== *)

(** Walph loop state *)
(** Walph state machine for iterative task processing
    Thread-safe implementation using stdlib Mutex for production use.

    Design notes:
    - Uses Mutex for thread-safe state access (stdlib, not Eio)
    - Condition variable for pause/resume (no busy-wait)
    - Fun.protect for exception safety (no zombie states)
    - Atomic check-and-set pattern to prevent double-start race
*)
type walph_state = {
  mutable running : bool;
  mutable paused : bool;
  mutable stop_requested : bool;
  mutable current_preset : string;
  mutable iterations : int;
  mutable completed : int;
  mutex : Mutex.t;       (* Thread safety for state access *)
  cond : Condition.t;    (* Proper wait for pause/resume, no busy-wait *)
}

(** Global Walph state table with its own mutex for thread-safe access *)
let walph_states : (string, walph_state) Hashtbl.t = Hashtbl.create 16
let walph_states_mutex = Mutex.create ()

(** Get or create Walph state for a room (thread-safe) *)
let get_walph_state config =
  let key = config.base_path in
  Mutex.lock walph_states_mutex;
  (* Deadlock fix: use Fun.protect to ensure unlock on exception *)
  Fun.protect ~finally:(fun () -> Mutex.unlock walph_states_mutex) (fun () ->
    match Hashtbl.find_opt walph_states key with
    | Some s -> s
    | None ->
        let s = {
          running = false; paused = false; stop_requested = false;
          current_preset = ""; iterations = 0; completed = 0;
          mutex = Mutex.create ();
          cond = Condition.create ();
        } in
        Hashtbl.replace walph_states key s;
        s
  )

(** Remove Walph state for a room (cleanup) *)
let remove_walph_state config =
  let key = config.base_path in
  Mutex.lock walph_states_mutex;
  (* Deadlock fix: use Fun.protect to ensure unlock on exception *)
  Fun.protect ~finally:(fun () -> Mutex.unlock walph_states_mutex) (fun () ->
    Hashtbl.remove walph_states key
  )

(** Run with Walph state mutex locked *)
let with_walph_lock state f =
  Mutex.lock state.mutex;
  Common.protect ~module_name:"room" ~finally_label:"finalizer" ~finally:(fun () -> Mutex.unlock state.mutex) f

(** Parse @walph command from broadcast message
    Returns: (command, args) or None if not a walph command *)
let parse_walph_command content =
  (* Match @walph COMMAND [args] pattern *)
  if not (try ignore (Str.search_forward (Str.regexp_case_fold "@walph") content 0); true
          with Not_found -> false) then
    None
  else begin
    (* Extract command after @walph *)
    (* Match @walph followed by command word (any non-whitespace, excluding newlines) *)
    let re = Str.regexp_case_fold "@walph[ \t]+\\([^ \t\n\r]+\\)\\(.*\\)" in
    if Str.string_match re content 0 then
      let cmd = String.uppercase_ascii (Str.matched_group 1 content) in
      let args = String.trim (try Str.matched_group 2 content with Not_found -> "") in
      Some (cmd, args)
    (* Only bare @walph (nothing after except optional whitespace) = STATUS *)
    else if Str.string_match (Str.regexp_case_fold "@walph[ \t]*$") content 0 then
      Some ("STATUS", "")
    else
      None
  end

(** Handle @walph control command (thread-safe)
    @param config Room configuration
    @param from_agent Agent sending the command
    @param command Command (STOP, PAUSE, RESUME, STATUS)
    @param args Command arguments
    @return Response message *)
let walph_control config ~from_agent ~command ~args =
  let state = get_walph_state config in
  let response = with_walph_lock state (fun () ->
    match command with
    | "STOP" ->
        if state.running then begin
          state.stop_requested <- true;
          Condition.broadcast state.cond;  (* Wake up pause wait *)
          Printf.sprintf "🛑 @walph STOP requested by %s (will stop after current iteration)" from_agent
        end else
          "ℹ️ @walph is not currently running"
    | "PAUSE" ->
        if state.running && not state.paused then begin
          state.paused <- true;
          Printf.sprintf "⏸️ @walph PAUSED by %s (use @walph RESUME to continue)" from_agent
        end else if state.paused then
          "ℹ️ @walph is already paused"
        else
          "ℹ️ @walph is not currently running"
    | "RESUME" ->
        if state.paused then begin
          state.paused <- false;
          Condition.broadcast state.cond;  (* Wake up pause wait *)
          Printf.sprintf "▶️ @walph RESUMED by %s" from_agent
        end else if state.running then
          "ℹ️ @walph is already running"
        else
          "ℹ️ @walph is not currently running"
    | "STATUS" ->
        if state.running then
          Printf.sprintf "📊 @walph STATUS: %s (iter: %d, done: %d, paused: %b)"
            state.current_preset state.iterations state.completed state.paused
        else
          "ℹ️ @walph is idle (use @walph START <preset> to begin)"
    | "START" ->
        (* START is handled by walph_loop, just acknowledge here *)
        if state.running then
          Printf.sprintf "⚠️ @walph is already running %s. Use @walph STOP first." state.current_preset
        else
          Printf.sprintf "✨ @walph START acknowledged. Args: %s" args
    | _ ->
        Printf.sprintf "❓ Unknown @walph command: %s. Valid: START, STOP, PAUSE, RESUME, STATUS" command
  ) in
  (* Broadcast the response *)
  let _ = broadcast config ~from_agent:"walph" ~content:response in
  response

(** Check if Walph should continue looping (thread-safe, no busy-wait)
    Uses Condition.wait for proper pause synchronization.
    @return true if should continue, false if should stop *)
let walph_should_continue config =
  let state = get_walph_state config in
  with_walph_lock state (fun () ->
    if state.stop_requested then false
    else if state.paused then begin
      (* Wait on condition variable - no busy-wait! *)
      (* Condition.wait atomically releases mutex and waits *)
      while state.paused && not state.stop_requested do
        Condition.wait state.cond state.mutex
      done;
      not state.stop_requested
    end else true
  )

(** Map Walph preset to task type (native-only)
    @param preset The loop preset (coverage, refactor, docs, review, figma, drain)
    @return Some chain_id for presets with corresponding chains, None for drain *)
let get_chain_id_for_preset = function
  | "coverage" -> Some "walph-coverage"
  | "refactor" -> Some "walph-refactor"
  | "docs" -> Some "walph-docs"
  | "review" -> Some "pr-review-pipeline"  (* PR self-review *)
  | "figma" -> Some "walph-figma"  (* Vision-first Figma loop *)
  | "drain" -> None  (* No chain for simple drain *)
  | _ -> None

(** Walph pattern: Keep claiming tasks until stop condition
    Thread-safe with atomic check-and-set and exception safety.

    @param preset Loop preset (drain, coverage, refactor, docs)
    @param max_iterations Maximum iterations before forced stop
    @param target Target file/directory for preset
    @return Status string with loop results *)
let walph_loop config ~agent_name ?(preset="drain") ?(max_iterations=10) ?target () =
  ensure_initialized config;

  (* Get Walph state *)
  let walph_state = get_walph_state config in

  (* Atomic check-and-set to prevent double-start race condition *)
  let start_result = with_walph_lock walph_state (fun () ->
    if walph_state.running then
      Error (Printf.sprintf "⚠️ @walph is already running %s. Use @walph STOP first." walph_state.current_preset)
    else begin
      (* Atomically set running=true under lock *)
      walph_state.running <- true;
      walph_state.paused <- false;
      walph_state.stop_requested <- false;
      walph_state.current_preset <- preset;
      walph_state.iterations <- 0;
      walph_state.completed <- 0;
      Ok ()
    end
  ) in

  match start_result with
  | Error msg ->
      let _ = broadcast config ~from_agent:"walph" ~content:msg in
      msg
  | Ok () ->
      (* Use Fun.protect to ensure running <- false even on exceptions (zombie prevention) *)
      let stop_reason = ref "" in

      Common.protect ~module_name:"room" ~finally_label:"finalizer"
        ~finally:(fun () ->
          (* Always reset running state, even on exception *)
          with_walph_lock walph_state (fun () ->
            walph_state.running <- false
          ))
        (fun () ->
          let _ = broadcast config ~from_agent:agent_name
            ~content:(Printf.sprintf "🔄 @walph START %s%s (max: %d)"
              preset
              (match target with Some t -> " --target " ^ t | None -> "")
              max_iterations) in

	          let failed_task_ids : (string, unit) Hashtbl.t = Hashtbl.create 16 in
	          let failed_task_id_list () =
	            Hashtbl.fold (fun task_id () acc -> task_id :: acc) failed_task_ids []
	          in
	          let mark_failed task_id =
	            Hashtbl.replace failed_task_ids task_id ()
	          in
	          let release_on_error ~task_id ~error =
	            let release_result =
	              transition_task_r config ~agent_name ~task_id ~action:"release" ()
	            in
	            let release_status =
	              match release_result with
	              | Ok _ -> "ok"
	              | Error e ->
	                  Printf.eprintf "[room] walph release failed: %s\n%!"
	                    (Types.masc_error_to_string e);
	                  "error"
	            in
	            log_event config
	              (Printf.sprintf
	                 "{\"type\":\"walph_task_released\",\"agent\":\"%s\",\"task\":\"%s\",\"error\":%s,\"release\":\"%s\",\"ts\":\"%s\"}"
	                 agent_name task_id
	                 (Yojson.Safe.to_string (`String error))
	                 release_status
	                 (now_iso ()))
	          in

	          (* Run the loop *)
	          let rec loop () =
	            (* Check control state before each iteration *)
	            if not (walph_should_continue config) then begin
              stop_reason := if walph_state.stop_requested then "stop requested" else "paused indefinitely";
              ()
            end else begin
              (* Check max iterations with lock *)
              let should_stop = with_walph_lock walph_state (fun () ->
                if walph_state.iterations >= max_iterations then begin
                  stop_reason := Printf.sprintf "max_iterations reached (%d)" max_iterations;
                  true
                end else begin
                  walph_state.iterations <- walph_state.iterations + 1;
                  false
                end
	              ) in
	              if should_stop then ()
	              else begin
	                (* Try to claim next task *)
	                let claim_result =
	                  claim_next_r config ~agent_name
	                    ~exclude_task_ids:(failed_task_id_list ()) ()
	                in
	                match claim_result with
	                | Claim_next_no_unclaimed ->
	                    stop_reason := "backlog drained"
	                | Claim_next_no_eligible _ ->
	                    stop_reason := "no eligible tasks (failed_this_run)"
	                | Claim_next_error err ->
	                    stop_reason := Printf.sprintf "claim error: %s" err
	                | Claim_next_claimed { task_id; message = claim_message; _ } ->
	                    if preset = "drain" then begin
	                      let done_result =
	                        transition_task_r config ~agent_name ~task_id ~action:"done"
	                          ~notes:"walph drain mode auto-complete" ()
	                      in
	                      match done_result with
	                      | Ok _ ->
	                          with_walph_lock walph_state (fun () ->
	                            walph_state.completed <- walph_state.completed + 1
	                          );
	                          log_event config
	                            (Printf.sprintf
	                               "{\"type\":\"walph_task_done\",\"agent\":\"%s\",\"task\":\"%s\",\"preset\":\"%s\",\"ts\":\"%s\"}"
	                               agent_name task_id preset (now_iso ()));
	                          let _ = broadcast config ~from_agent:agent_name
	                            ~content:(Printf.sprintf "📊 @walph Iteration %d: %s ✅" walph_state.iterations claim_message) in
	                          loop ()
	                      | Error err ->
	                          let err_msg = Types.masc_error_to_string err in
	                          mark_failed task_id;
	                          release_on_error ~task_id ~error:err_msg;
	                          let _ = broadcast config ~from_agent:agent_name
	                            ~content:(Printf.sprintf "⚠️ @walph done error on %s: %s (released)" task_id err_msg) in
	                          loop ()
	                    end else begin
	                      (* Sync walph does not execute LLM chains; release safely instead of leaving claim stuck. *)
	                      let err_msg =
	                        Printf.sprintf "preset %s requires eio walph runner" preset
	                      in
	                      mark_failed task_id;
	                      release_on_error ~task_id ~error:err_msg;
	                      let _ = broadcast config ~from_agent:agent_name
	                        ~content:(Printf.sprintf "⚠️ @walph unsupported preset in sync loop for %s: %s (released)" task_id err_msg) in
	                      loop ()
	                    end
	              end
	            end
	          in

          loop ();

          (* Final broadcast and log *)
          let result = Printf.sprintf
            "🛑 @walph STOPPED. Preset: %s, Iterations: %d, Tasks completed: %d, Reason: %s"
            preset walph_state.iterations walph_state.completed !stop_reason in

          let _ = broadcast config ~from_agent:agent_name ~content:result in

          log_event config (Printf.sprintf
            "{\"type\":\"walph_loop_complete\",\"agent\":\"%s\",\"preset\":\"%s\",\"iterations\":%d,\"completed\":%d,\"reason\":\"%s\",\"ts\":\"%s\"}"
            agent_name preset walph_state.iterations walph_state.completed !stop_reason (now_iso ()));

          result
        )

(** Update task priority *)
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
    with e ->
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

(** Get raw agent list (for orchestrator) *)
let get_agents_raw config =
  ensure_initialized config;
  let agents_path = agents_dir_in_room config (current_room_id config) in
  if not (Sys.file_exists agents_path) then []
  else
    Sys.readdir agents_path
    |> Array.to_list
    |> List.filter (fun name -> Filename.check_suffix name ".json")
    |> List.filter_map (fun name ->
        let path = Filename.concat agents_path name in
        let json = read_json config path in
        match agent_of_yojson json with
        | Ok agent -> Some agent
        | Error _ -> None
      )

let get_agents_raw_in_room config room_id =
  if not (root_is_initialized config) then []
  else
    let agents_path = agents_dir_in_room config room_id in
    if not (Sys.file_exists agents_path) then []
    else
      Sys.readdir agents_path
      |> Array.to_list
      |> List.filter (fun name -> Filename.check_suffix name ".json")
      |> List.filter_map (fun name ->
          let path = Filename.concat agents_path name in
          let json = read_json config path in
          match agent_of_yojson json with
          | Ok agent -> Some agent
          | Error _ -> None
        )

(** Audit tasks: find claimed/in_progress tasks whose assignees are not active agents. *)
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
            let path = Filename.concat agents_path name in
            let json = read_json config path in
            match agent_of_yojson json with
            | Ok agent -> Some agent.name
            | Error _ -> None)
      else []
    in
    let backlog = read_backlog config in
    List.filter_map (fun (task : Types.task) ->
      match task.task_status with
      | Types.Claimed { assignee; _ }
      | Types.InProgress { assignee; _ } ->
          if List.mem assignee active_names then None
          else Some (task, assignee)
      | _ -> None
    ) backlog.tasks

let is_agent_joined_in_room config ~room_id ~agent_name =
  if not (root_is_initialized config) then false
  else
    let actual_name = resolve_agent_name_in_room config ~room_id agent_name in
    let filename = safe_filename actual_name ^ ".json" in
    (* Check room-scoped path first *)
    let room_agents = agents_dir_in_room config room_id in
    let room_path = Filename.concat room_agents filename in
    if path_exists config room_path then true
    else
      (* Fallback: check root agents_dir (where default join writes) *)
      let root_agents = agents_dir config in
      let root_path = Filename.concat root_agents filename in
      path_exists config root_path

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
        if extract_seq_from_filename name <= since_seq then List.rev acc
        else
          let path = Filename.concat msgs_path name in
          match read_json config path with
          | json ->
              (match message_of_yojson json with
               | Ok msg when msg.seq > since_seq -> loop (remaining - 1) (msg :: acc) rest
               | _ -> loop remaining acc rest)
          | exception e ->
              Eio.traceln "[WARN] Failed to read %s %s: %s" warn_label name (Printexc.to_string e);
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

(** Get all agents with their status *)
let get_agents_status config =
  ensure_initialized config;

  let agents_path = agents_dir config in
  if not (Sys.file_exists agents_path) then
    `Assoc [("agents", `List []); ("count", `Int 0)]
  else begin
    let agents = ref [] in
    Sys.readdir agents_path |> Array.iter (fun name ->
      if Filename.check_suffix name ".json" then begin
        let path = Filename.concat agents_path name in
        let json = read_json config path in
        match agent_of_yojson json with
        | Ok agent ->
            let is_zombie = is_zombie_agent ~agent_name:agent.name agent.last_seen in
            let status = if is_zombie then "zombie" else agent_status_to_string agent.status in
            agents := `Assoc [
              ("name", `String agent.name);
              ("status", `String status);
              ("is_zombie", `Bool is_zombie);
              ("current_task", match agent.current_task with Some t -> `String t | None -> `Null);
              ("last_seen", `String agent.last_seen);
              ("capabilities", `List (List.map (fun s -> `String s) agent.capabilities));
            ] :: !agents
        | Error msg ->
            Printf.eprintf "[room] agent state read failed: %s\n%!" msg
      end
    );
    `Assoc [
      ("agents", `List (List.rev !agents));
      ("count", `Int (List.length !agents));
    ]
  end

(* ============================================ *)
(* Agent Discovery - Capability Broadcasting   *)
(* ============================================ *)

(** Register agent capabilities *)
let register_capabilities config ~agent_name ~capabilities =
  ensure_initialized config;

  (* Support both exact nickname and agent_type prefix match *)
  let actual_name = resolve_agent_name config agent_name in
  let agent_file = Filename.concat (agents_dir config) (safe_filename actual_name ^ ".json") in
  if Sys.file_exists agent_file then begin
    with_file_lock config agent_file (fun () ->
      let json = read_json config agent_file in
      match agent_of_yojson json with
      | Ok agent ->
          let updated = { agent with capabilities; last_seen = now_iso () } in
          write_json config agent_file (agent_to_yojson updated);

          (* Log event *)
          log_event config (Printf.sprintf
            "{\"type\":\"capabilities_registered\",\"agent\":\"%s\",\"capabilities\":%s,\"ts\":\"%s\"}"
            actual_name
            (Yojson.Safe.to_string (`List (List.map (fun s -> `String s) capabilities)))
            (now_iso ()));

          Printf.sprintf "📡 %s capabilities: %s" actual_name (String.concat ", " capabilities)
      | Error _ ->
          Printf.sprintf "⚠ Invalid agent file for %s" actual_name
    )
  end else
    Printf.sprintf "⚠ Agent %s not found. Join first!" agent_name

(** Update agent metadata (status/capabilities). *)
let update_agent_r config ~agent_name ?status ?capabilities () : string Types.masc_result =
  if not (is_initialized config) then Error Types.NotInitialized
  else match validate_agent_name_r agent_name with
    | Error e -> Error e
    | Ok _ ->
        let actual_name = resolve_agent_name config agent_name in
        let agent_file = Filename.concat (agents_dir config) (safe_filename actual_name ^ ".json") in
        if not (Sys.file_exists agent_file) then
          Error (Types.AgentNotFound actual_name)
        else
          let locked =
            with_file_lock_r config agent_file (fun () ->
              let json = read_json config agent_file in
              match agent_of_yojson json with
              | Error _ -> Error (Types.InvalidJson "Invalid agent file")
              | Ok agent ->
                  let status_opt =
                    match status with
                    | None -> Ok None
                    | Some s ->
                        (match Types.agent_status_of_string_opt (String.lowercase_ascii s) with
                         | Some st -> Ok (Some st)
                         | None -> Error (Types.InvalidJson ("Unknown status: " ^ s)))
                  in
                  (match status_opt with
                   | Error e -> Error e
                   | Ok maybe_status ->
                       let invalid =
                         match agent.current_task, maybe_status with
                         | Some _, Some Types.Inactive ->
                             Some "Cannot set inactive while a task is assigned"
                         | None, Some Types.Busy ->
                             Some "Cannot set busy without an active task"
                         | _ -> None
                       in
                       (match invalid with
                        | Some msg -> Error (Types.TaskInvalidState msg)
                        | None ->
                            let updated_caps =
                              match capabilities with
                              | None -> agent.capabilities
                              | Some caps -> caps
                            in
                            let updated_status =
                              match maybe_status with
                              | None -> agent.status
                              | Some st -> st
                            in
                            let updated = {
                              agent with
                              status = updated_status;
                              capabilities = updated_caps;
                              last_seen = now_iso ();
                            } in
                            write_json config agent_file (agent_to_yojson updated);
                            log_event config (Printf.sprintf
                              "{\"type\":\"agent_update\",\"agent\":\"%s\",\"status\":\"%s\",\"capabilities\":%s,\"ts\":\"%s\"}"
                              actual_name
                              (Types.agent_status_to_string updated_status)
                              (Yojson.Safe.to_string (`List (List.map (fun s -> `String s) updated_caps)))
                              (now_iso ()));
                            Ok (Printf.sprintf "✅ %s updated" actual_name)
                       ))
            )
          in
          (match locked with
           | Ok (Ok msg) -> Ok msg
           | Ok (Error e) -> Error e
           | Error e -> Error e)

(** Find agents by capability *)
let find_agents_by_capability config ~capability =
  ensure_initialized config;

  let agents_path = agents_dir config in
  if not (Sys.file_exists agents_path) then
    `Assoc [("agents", `List []); ("count", `Int 0)]
  else begin
    let matching = ref [] in
    Sys.readdir agents_path |> Array.iter (fun name ->
      if Filename.check_suffix name ".json" then begin
        let path = Filename.concat agents_path name in
        let json = read_json config path in
        match agent_of_yojson json with
        | Ok agent when List.mem capability agent.capabilities && not (is_zombie_agent ~agent_name:agent.name agent.last_seen) ->
            matching := `Assoc [
              ("name", `String agent.name);
              ("status", `String (agent_status_to_string agent.status));
              ("capabilities", `List (List.map (fun s -> `String s) agent.capabilities));
            ] :: !matching
        | _ -> ()
      end
    );
    `Assoc [
      ("capability", `String capability);
      ("agents", `List (List.rev !matching));
      ("count", `Int (List.length !matching));
    ]
  end

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

(** Slugify a string for use as room ID *)
let slugify name =
  String.lowercase_ascii name
  |> String.map (fun c ->
      if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') then c
      else '-')
  |> (fun s ->
      (* Remove leading/trailing dashes and collapse multiple dashes *)
      let rec collapse acc prev_dash = function
        | [] -> List.rev acc
        | '-' :: rest when prev_dash -> collapse acc true rest
        | '-' :: rest -> collapse ('-' :: acc) true rest
        | c :: rest -> collapse (c :: acc) false rest
      in
      String.to_seq s |> List.of_seq |> collapse [] true |> List.to_seq |> String.of_seq)
  |> (fun s ->
      let len = String.length s in
      if len > 0 && s.[0] = '-' then String.sub s 1 (len - 1) else s)
  |> (fun s ->
      let len = String.length s in
      if len > 0 && s.[len - 1] = '-' then String.sub s 0 (len - 1) else s)

(** Get rooms directory path *)
let rooms_dir config = rooms_root_dir config

(** Get room registry file path *)
let registry_path config = registry_root_path config

(** Get current room file path *)
let current_room_path config = current_room_root_path config

(** Read current room ID *)
let read_current_room config =
  let read_from path =
    match Safe_ops.read_file_safe path with
    | Ok content ->
      let trimmed = String.trim content in
      if trimmed = "" then None else Some trimmed
    | Error _ -> None
  in
  match read_from (current_room_path config) with
  | Some room_id -> Some room_id
  | None ->
      (match read_from (legacy_current_room_path config) with
       | Some legacy_room -> Some legacy_room
       | None -> Some "default")

(** Write current room ID *)
let write_current_room config room_id =
  let write_to path =
    mkdir_p (Filename.dirname path);
    let oc = open_out path in
    output_string oc room_id;
    output_char oc '\n';
    close_out oc
  in
  (* Canonical location inside .masc/ *)
  write_to (current_room_path config);
  (* Legacy compatibility: keep base_path/current_room in sync *)
  write_to (legacy_current_room_path config)

(** Get path for a specific room *)
let room_path config room_id = room_dir_for config room_id

(** Count agents in a room *)
let count_agents_in_room config room_id =
  List.length (get_agents_raw_in_room config room_id)

(** Count tasks in a room *)
let count_tasks_in_room config room_id =
  get_tasks_raw_in_room config room_id
  |> List.fold_left (fun acc (task : Types.task) ->
         match task.task_status with
         | Types.Todo | Types.Claimed _ | Types.InProgress _ -> acc + 1
         | Types.Done _ | Types.Cancelled _ -> acc
       ) 0

(** Load room registry *)
let load_registry config : Types.room_registry =
  let default_registry =
    { rooms = []; default_room = "default"; current_room = Some "default" }
  in
  let parse_registry json =
    match Types.room_registry_of_yojson json with
    | Ok registry -> registry
    | Error _ -> default_registry
  in
  let root_path = registry_path config in
  let legacy_path = legacy_registry_root_path config in
  if path_exists_root config root_path then
    parse_registry (read_json_root config root_path)
  else if Sys.file_exists legacy_path then
    (* Legacy fallback: migrate rooms.json into .masc/ root. *)
    let legacy_registry = parse_registry (read_json_local legacy_path) in
    write_json_root config root_path (Types.room_registry_to_yojson legacy_registry);
    legacy_registry
  else
    default_registry

(** Save room registry *)
let save_registry config (registry : Types.room_registry) =
  let path = registry_path config in
  mkdir_p (rooms_dir config);
  write_json_root config path (Types.room_registry_to_yojson registry);
  (* Keep legacy location in sync for older clients. *)
  write_json_local (legacy_registry_root_path config) (Types.room_registry_to_yojson registry)

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
            with e -> Printf.eprintf "[WARN] room: auto-leave from %s failed: %s\n%!" prev (Printexc.to_string e))
       | _ -> ());

      (* Update current room *)
      write_current_room config room_id;

      (* Initialize the room on first entry (no auto-join). *)
      if not (is_initialized config) then
        (try ignore (init config ~agent_name:None)
         with e -> Printf.eprintf "[WARN] room: init failed for %s: %s\n%!" room_id (Printexc.to_string e));

      (* Join the new room *)
      let join_result = join config ~agent_name:effective_agent_name ~capabilities:[] () in

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
