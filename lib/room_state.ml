(** Room State - Foundation state management functions.

    Contains: state read/write/update, backlog management, broadcast,
    agent name resolution, room bootstrap, and zombie detection helpers.

    Extracted from room.ml to enable Room_gc, Room_vote, and other
    sub-modules to access these without circular dependencies. *)

open Types
open Room_utils

(* ============================================ *)
(* State Read / Write / Update                  *)
(* ============================================ *)

(** Read room state — checks PostgreSQL first for HTTP state persistence *)
let read_state config =
  let pg_state =
    if is_pg_backend config then
      match backend_get config ~key:"room:state" with
      | Ok (Some json_str) ->
          (try Some (Yojson.Safe.from_string json_str) with Yojson.Json_error _ -> None)
      | Ok None | Error _ -> None
    else None
  in
  let json = match pg_state with
    | Some j -> j
    | None -> read_json config (state_path config)
  in
  match room_state_of_yojson json with
  | Ok state -> state
  | Error _ -> {
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
    }

(** Write room state — persists to both filesystem and PostgreSQL *)
let write_state config state =
  write_json config (state_path config) (room_state_to_yojson state);
  if is_pg_backend config then begin
    let json_str = Yojson.Safe.to_string (room_state_to_yojson state) in
    (match backend_set config ~key:"room:state" ~value:json_str with
     | Ok () -> ()
     | Error e -> Log.Misc.error "room_state write_state backend_set failed: %s" (Backend.show_error e))
  end

(** Update state with function - uses file lock for atomic read-modify-write *)
let update_state config f =
  with_file_lock config (state_path config) (fun () ->
    let state = read_state config in
    let new_state = f state in
    write_state config new_state;
    new_state
  )

(** @deprecated Use [read_state (with_scope config (Named room_id))] instead. *)
let state_path_in_room config room_id =
  state_path (with_scope config (Named room_id))

let read_state_in_room config room_id =
  read_state (with_scope config (Named room_id))

let write_state_in_room config room_id state =
  write_state (with_scope config (Named room_id)) state

let update_state_in_room config room_id f =
  update_state (with_scope config (Named room_id)) f

(* ============================================ *)
(* Sequence Numbers                             *)
(* ============================================ *)

(** Get next message sequence *)
let next_seq config =
  let state = update_state config (fun s -> { s with message_seq = s.message_seq + 1 }) in
  state.message_seq

let next_seq_in_room config room_id =
  next_seq (with_scope config (Named room_id))

(* ============================================ *)
(* Pause State                                  *)
(* ============================================ *)

(** Check if room is paused *)
let is_paused config =
  let state = read_state config in
  state.paused

(** Get pause info *)
let pause_info config =
  let state = read_state config in
  if state.paused then
    Some (state.paused_by, state.pause_reason, state.paused_at)
  else
    None

(* ============================================ *)
(* Backlog Management                           *)
(* ============================================ *)

(** Read backlog *)
let read_backlog config =
  let json = read_json config (backlog_path config) in
  match backlog_of_yojson json with
  | Ok backlog -> backlog
  | Error _ -> { tasks = []; last_updated = now_iso (); version = 1 }

(** Write backlog *)
let write_backlog config backlog =
  write_json config (backlog_path config) (backlog_to_yojson backlog)

let current_room_id config =
  read_current_room config |> Option.value ~default:"default"

(** @deprecated Use [agents_dir (with_scope config (Named room_id))] instead. *)
let agents_dir_in_room config room_id =
  agents_dir (with_scope config (Named room_id))

let tasks_dir_in_room config room_id =
  tasks_dir (with_scope config (Named room_id))

let messages_dir_in_room config room_id =
  messages_dir (with_scope config (Named room_id))

let backlog_path_in_room config room_id =
  backlog_path (with_scope config (Named room_id))

let read_backlog_in_room config room_id =
  read_backlog (with_scope config (Named room_id))

(* ============================================ *)
(* Task ID / Archive Management                 *)
(* ============================================ *)

(** Parse task id like "task-001" -> 1 *)
let task_id_to_int id =
  let prefix = "task-" in
  let prefix_len = String.length prefix in
  if String.length id <= prefix_len then None
  else if String.sub id 0 prefix_len <> prefix then None
  else int_of_string_opt (String.sub id prefix_len (String.length id - prefix_len))

(** Read archived task ids for collision-free task numbering *)
let read_archive_task_ids config =
  if not (Sys.file_exists (archive_path config)) then []
  else
    let open Yojson.Safe.Util in
    let json = read_json config (archive_path config) in
    let tasks =
      match json with
      | `List tasks -> tasks
      | `Assoc _ -> begin
          match json |> member "tasks" with
          | `List tasks -> tasks
          | _ -> []
        end
      | _ -> []
    in
    List.filter_map (fun task ->
      match task |> member "id" |> to_string_option with
      | Some id -> task_id_to_int id
      | None -> None
    ) tasks

(** Append tasks to archive file (tasks-archive.json) *)
let append_archive_tasks config (tasks : task list) =
  if tasks = [] then ()
  else begin
    let open Yojson.Safe.Util in
    let path = archive_path config in
    let existing = read_json config path in
    let existing_tasks =
      match existing with
      | `List items -> items
      | `Assoc _ -> begin
          match existing |> member "tasks" with
          | `List items -> items
          | _ -> []
        end
      | _ -> []
    in
    let new_tasks = List.map task_to_yojson tasks in
    (* Deduplicate by task id, preserving first occurrence *)
    let seen = Hashtbl.create 64 in
    let dedup = List.filter (fun json ->
      match json |> member "id" |> to_string_option with
      | Some id ->
          if Hashtbl.mem seen id then false
          else (Hashtbl.add seen id (); true)
      | None -> false
    ) (existing_tasks @ new_tasks)
    in
    let archive_json = `Assoc [
      ("tasks", `List dedup);
      ("last_updated", `String (now_iso ()));
    ] in
    write_json config path archive_json
  end

(** Calculate next task id using backlog + archive to avoid reuse *)
let next_task_number config backlog =
  let backlog_ids = List.filter_map (fun task -> task_id_to_int task.id) backlog.tasks in
  let archive_ids = read_archive_task_ids config in
  let max_id = List.fold_left max 0 (backlog_ids @ archive_ids) in
  max_id + 1

(* ============================================ *)
(* Session / Agent Helpers                      *)
(* ============================================ *)

(** Generate short session ID *)
let generate_session_id () =
  Printf.sprintf "%04x%04x" (Random.int 0xFFFF) (Random.int 0xFFFF)

(** Get hostname *)
let get_hostname () =
  try Some (Unix.gethostname ()) with Unix.Unix_error _ -> None

(** Get current TTY - uses TTY environment variable or /dev/tty check *)
let get_tty () =
  try
    match Sys.getenv_opt "TTY" with
    | Some tty -> Some tty
    | None ->
        try
          if Unix.isatty Unix.stdin then
            let output = Process_eio.run_argv ~timeout_sec:5.0 ["tty"] in
            let trimmed = String.trim output in
            if String.length trimmed > 0 then Some trimmed else None
          else None
        with Unix.Unix_error _ -> None
  with e ->
    Log.Misc.error "get_tty failed: %s" (Printexc.to_string e);
    None

(** Resolve agent name - supports both exact nickname and agent_type prefix match.
    Returns the actual agent name (nickname) if found, otherwise original name. *)
let resolve_agent_name config agent_name =
  let exact_file = Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json") in
  if Sys.file_exists exact_file then
    agent_name
  else begin
    let dir = agents_dir config in
    if Sys.file_exists dir then
      let files = Sys.readdir dir in
      let prefix = agent_name ^ "-" in
      match Array.find_opt (fun f ->
        String.length f > String.length prefix &&
        String.sub f 0 (String.length prefix) = prefix
      ) files with
      | Some file -> String.sub file 0 (String.length file - 5) (* remove .json *)
      | None -> agent_name
    else
      agent_name
  end

(** @deprecated Use [resolve_agent_name (with_scope config (Named room_id))] instead. *)
let resolve_agent_name_in_room config ~room_id agent_name =
  resolve_agent_name (with_scope config (Named room_id)) agent_name

(* ============================================ *)
(* Room Bootstrap                               *)
(* ============================================ *)

(** Default empty state for bootstrap. *)
let default_room_state config = {
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
}

let ensure_room_bootstrap config room_id =
  (* 1. Always ensure root infrastructure exists *)
  let root_dir = masc_root_dir config in
  let root_agents_dir = Filename.concat root_dir "agents" in
  let root_tasks_dir = Filename.concat root_dir "tasks" in
  let root_messages_dir = Filename.concat root_dir "messages" in
  let root_backlog_path = Filename.concat root_tasks_dir "backlog.json" in
  List.iter mkdir_p [ root_agents_dir; root_tasks_dir; root_messages_dir; rooms_root_dir config ];
  if not (path_exists_root config (root_state_path config)) then
    write_json_root config (root_state_path config)
      (room_state_to_yojson (default_room_state config));
  if not (path_exists_root config root_backlog_path) then
    write_json_root config root_backlog_path
      (backlog_to_yojson { tasks = []; last_updated = now_iso (); version = 1 });

  (* 2. Bootstrap the target room via scoped config — unified path *)
  let scoped = with_scope config (Named room_id) in
  let scoped_agents = agents_dir scoped in
  let scoped_tasks = tasks_dir scoped in
  let scoped_messages = messages_dir scoped in
  let scoped_state = state_path scoped in
  let scoped_backlog = backlog_path scoped in
  List.iter mkdir_p [ masc_dir scoped; scoped_agents; scoped_tasks; scoped_messages ];
  if not (path_exists scoped scoped_state) then
    write_json scoped scoped_state (room_state_to_yojson (default_room_state config));
  if not (path_exists scoped scoped_backlog) then
    write_json scoped scoped_backlog
      (backlog_to_yojson { tasks = []; last_updated = now_iso (); version = 1 })

(* ============================================ *)
(* Broadcast                                    *)
(* ============================================ *)

(** @deprecated Use [broadcast (with_scope config (Named room_id))] instead. *)
let broadcast_in_room config ~room_id ~from_agent ~content =
  let scoped = with_scope config (Named room_id) in
  ensure_room_bootstrap scoped room_id;
  let seq = next_seq scoped in

  let mention = Mention.extract content in
  let safe_content = sanitize_message content in
  let safe_agent = sanitize_agent_name from_agent in
  let msg = {
    seq;
    from_agent = safe_agent;
    msg_type = "broadcast";
    content = safe_content;
    mention;
    timestamp = now_iso ();
  } in
  let msg_file =
    Filename.concat (messages_dir scoped)
      (Printf.sprintf "%09d_%s_broadcast.json" seq (safe_filename from_agent))
  in
  write_json scoped msg_file (message_to_yojson msg);
  (match backend_publish scoped ~channel:(Printf.sprintf "broadcast:%s" room_id)
      ~message:(Yojson.Safe.to_string (message_to_yojson msg)) with
   | Ok _ -> ()
   | Error e -> Log.Misc.error "broadcast_scoped publish failed for %s: %s" room_id (Backend.show_error e));
  Printf.sprintf "📢 [%s@%s] %s" safe_agent room_id safe_content

let broadcast config ~from_agent ~content =
  ensure_initialized config;
  let seq = next_seq config in
  let mention = Mention.extract content in
  let safe_content = sanitize_message content in
  let safe_agent = sanitize_agent_name from_agent in
  let msg = {
    seq;
    from_agent = safe_agent;
    msg_type = "broadcast";
    content = safe_content;
    mention;
    timestamp = now_iso ();
  } in
  let msg_file =
    Filename.concat (messages_dir config)
      (Printf.sprintf "%09d_%s_broadcast.json" seq (safe_filename from_agent))
  in
  write_json config msg_file (message_to_yojson msg);
  let room_id = match config.scope with Default -> "default" | Named id -> id in
  (match backend_publish config ~channel:(Printf.sprintf "broadcast:%s" room_id)
      ~message:(Yojson.Safe.to_string (message_to_yojson msg)) with
   | Ok _ -> ()
   | Error e -> Log.Misc.error "broadcast publish failed for %s: %s" room_id (Backend.show_error e));
  Printf.sprintf "📢 [%s@%s] %s" safe_agent room_id safe_content

(* ============================================ *)
(* Zombie Detection Helpers                     *)
(* ============================================ *)

(** Default heartbeat timeout in seconds - delegates to Resilience *)
let heartbeat_timeout_seconds = Resilience.default_zombie_threshold

(** Parse ISO timestamp to Unix time - returns None if parsing fails *)
let parse_iso_time_opt = Resilience.Time.parse_iso8601_opt

(** Parse ISO timestamp - returns current time if parsing fails (safe default) *)
let parse_iso_time iso_str =
  match parse_iso_time_opt iso_str with
  | Some t -> t
  | None -> Resilience.Time.now ()

(** Check if agent is zombie (no heartbeat for timeout period).
    Uses keeper threshold for keeper agents, default threshold otherwise. *)
let is_zombie_agent ~agent_name last_seen_iso =
  Resilience.Zombie.is_zombie_for_agent ~agent_name last_seen_iso

let take n xs =
  if n <= 0 then []
  else
    let rec loop i acc = function
      | [] -> List.rev acc
      | _ when i <= 0 -> List.rev acc
      | x :: rest -> loop (i - 1) (x :: acc) rest
    in
    loop n [] xs
