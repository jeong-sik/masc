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

(* default_namespace_id removed — namespace concept retired (#unify-namespace).
   All coordination uses a single basepath-scoped identity. *)

let non_empty_string_opt = function
  | Some value ->
      let value = String.trim value in
      if value = "" then None else Some value
  | None -> None

let normalized_string_list values =
  let seen = Hashtbl.create (List.length values) in
  values
  |> List.filter_map (fun value -> non_empty_string_opt (Some value))
  |> List.filter (fun value ->
         if Hashtbl.mem seen value then
           false
         else (
           Hashtbl.add seen value ();
           true))

let recover_active_agent_name = function
  | `String name -> non_empty_string_opt (Some name)
  | `Assoc _ as json ->
      (match non_empty_string_opt (Safe_ops.json_string_opt "name" json) with
       | Some name -> Some name
       | None ->
           non_empty_string_opt (Safe_ops.json_string_opt "agent_name" json))
  | _ -> None

let recover_room_state config json =
  let defaults = default_room_state config in
  let active_agents =
    match Safe_ops.json_list_opt "active_agents" json with
    | Some agents -> List.filter_map recover_active_agent_name agents
    | None -> defaults.active_agents
  in
  {
    protocol_version =
      non_empty_string_opt (Safe_ops.json_string_opt "protocol_version" json)
      |> Option.value ~default:defaults.protocol_version;
    project =
      non_empty_string_opt (Safe_ops.json_string_opt "project" json)
      |> Option.value ~default:defaults.project;
    started_at =
      non_empty_string_opt (Safe_ops.json_string_opt "started_at" json)
      |> Option.value ~default:defaults.started_at;
    message_seq = Safe_ops.json_int ~default:defaults.message_seq "message_seq" json;
    active_agents;
    paused = Safe_ops.json_bool ~default:defaults.paused "paused" json;
    pause_reason =
      non_empty_string_opt (Safe_ops.json_string_opt "pause_reason" json);
    paused_by =
      non_empty_string_opt (Safe_ops.json_string_opt "paused_by" json);
    paused_at =
      non_empty_string_opt (Safe_ops.json_string_opt "paused_at" json);
    search_strategy_default =
      (match
         non_empty_string_opt
           (Safe_ops.json_string_opt "search_strategy_default" json)
       with
       | Some value -> Some value
       | None -> defaults.search_strategy_default);
    speculation_enabled =
      Safe_ops.json_bool ~default:defaults.speculation_enabled
        "speculation_enabled" json;
    speculation_budget =
      Safe_ops.json_int_opt "speculation_budget" json;
  }

(** Write room state — filesystem only.
    Room state is short-term coordination data (agent membership, heartbeats,
    task claims). Persisting to PG adds latency and compression overhead
    without benefit — agents re-join on server restart.
    See: memory-tier-phase1 design (Camp 4 pragmatist). *)
let write_state config state =
  let json = room_state_to_yojson state in
  write_json config (state_path config) json

(** Read room state — filesystem only.
    Room state is ephemeral coordination data; filesystem is the sole source
    of truth.  PG read path removed to eliminate ZSTD decompress dependency. *)
let read_state config =
  let json = read_json config (state_path config) in
  match room_state_of_yojson json with
  | Ok state -> state
  | Error msg ->
      let repaired = recover_room_state config json in
      let raw_snippet =
        let s = Yojson.Safe.to_string json in
        if String.length s <= 500 then s
        else String.sub s 0 500 ^ "...(truncated)"
      in
      Log.Misc.warn
        "read_state: deserialization failed (%s), raw=%s — repairing and rewriting"
        msg raw_snippet;
      (try write_state config repaired
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Log.Misc.warn "read_state: failed to persist repaired state: %s"
             (Printexc.to_string exn));
      repaired

(** Update state with function - uses file lock for atomic read-modify-write *)
let update_state config f =
  with_file_lock config (state_path config) (fun () ->
    let state = read_state config in
    let new_state = f state in
    write_state config new_state;
    new_state
  )

(* _in_room shims removed — rooms are flattened (#4638).
   Use read_state / write_state / update_state directly. *)

(* ============================================ *)
(* Sequence Numbers                             *)
(* ============================================ *)

(** Get next message sequence *)
let next_seq config =
  let state = update_state config (fun s -> { s with message_seq = s.message_seq + 1 }) in
  state.message_seq

(* next_seq_in_room removed — rooms are flattened (#4638). Use next_seq. *)

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
let read_backlog_r config =
  match read_json_result config (backlog_path config) with
  | Error msg -> Error msg
  | Ok json ->
      (match backlog_of_yojson json with
       | Ok backlog -> Ok backlog
       | Error msg ->
           Error
             (Printf.sprintf
                "[read_backlog] backlog decode failed for %s: %s"
                (backlog_path config)
                msg))

let read_backlog config =
  match read_backlog_r config with
  | Ok backlog -> backlog
  | Error msg ->
      Log.Misc.error "%s" msg;
      { tasks = []; last_updated = now_iso (); version = 1 }

(** Write backlog *)
let write_backlog config backlog =
  write_json config (backlog_path config) (backlog_to_yojson backlog)

(* activity_room_id removed — room/namespace retired (#unify-namespace). *)

let emit_message_activity config ~from_agent ~content ~mention
    ?session_id ?operation_id ?worker_run_id ?(evidence_refs = []) () =
  let evidence_refs = normalized_string_list evidence_refs in
  let payload =
    `Assoc
      [
        ("content", `String content);
        ( "mention",
          match mention with
          | Some value -> `String value
          | None -> `Null );
        ( "session_id",
          match session_id with
          | Some value when String.trim value <> "" -> `String value
          | _ -> `Null );
        ( "operation_id",
          match operation_id with
          | Some value when String.trim value <> "" -> `String value
          | _ -> `Null );
        ( "worker_run_id",
          match worker_run_id with
          | Some value when String.trim value <> "" -> `String value
          | _ -> `Null );
        ( "evidence_refs",
          `List (List.map (fun value -> `String value) evidence_refs) );
      ]
  in
  let actor = Room_hooks.{ kind = "agent"; id = from_agent } in
  let emit ?subject ~kind ~tags () =
    try
      !Room_hooks.activity_emit_fn config
        ~actor ?subject ~kind ~payload ~tags ()
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Log.Misc.warn "message activity emit failed (%s): %s" kind
          (Printexc.to_string exn)
  in
  emit ~kind:"message.broadcast" ~tags:[ "message"; "broadcast" ] ();
  match mention with
  | Some target when String.trim target <> "" ->
      emit
        ~subject:Room_hooks.{ kind = "agent"; id = target }
        ~kind:"message.mentioned"
        ~tags:[ "message"; "mention" ] ()
  | _ -> ()

(* _in_room path/backlog shims removed — rooms are flattened (#4638).
   Use tasks_dir / messages_dir / backlog_path / read_backlog directly. *)

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
  let t = Unix.gettimeofday () in
  Printf.sprintf "%04x%04x" (Hashtbl.hash t land 0xFFFF) (Hashtbl.hash (t *. 1000.0) land 0xFFFF)

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
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e ->
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

(* ============================================ *)
(* Room Bootstrap                               *)
(* ============================================ *)

let ensure_room_bootstrap config =
  (* 1. Always ensure root infrastructure exists *)
  let root_dir = masc_root_dir config in
  let root_agents_dir = Filename.concat root_dir "agents" in
  let root_keepers_dir = Filename.concat root_dir "keepers" in
  let root_traces_dir = Filename.concat root_dir "traces" in
  let root_tasks_dir = Filename.concat root_dir "tasks" in
  let root_messages_dir = Filename.concat root_dir "messages" in
  let root_backlog_path = Filename.concat root_tasks_dir "backlog.json" in
  List.iter mkdir_p
    [
      root_agents_dir;
      root_keepers_dir;
      root_traces_dir;
      root_tasks_dir;
      root_messages_dir;
    ];
  if not (path_exists_root config (root_state_path config)) then
    write_json_root config (root_state_path config)
      (room_state_to_yojson (default_room_state config));
  if not (path_exists_root config root_backlog_path) then
    write_json_root config root_backlog_path
      (backlog_to_yojson { tasks = []; last_updated = now_iso (); version = 1 });

  (* 2. Bootstrap scoped dirs — single namespace since #4638 *)
  let scoped_agents = agents_dir config in
  let scoped_tasks = tasks_dir config in
  let scoped_messages = messages_dir config in
  let scoped_state = state_path config in
  let scoped_backlog = backlog_path config in
  List.iter mkdir_p [ masc_dir config; scoped_agents; scoped_tasks; scoped_messages ];
  if not (path_exists config scoped_state) then
    write_json config scoped_state (room_state_to_yojson (default_room_state config));
  if not (path_exists config scoped_backlog) then
    write_json config scoped_backlog
      (backlog_to_yojson { tasks = []; last_updated = now_iso (); version = 1 })

let broadcast_channel config =
  Printf.sprintf "broadcast:%s:default" (project_prefix config)

(* ============================================ *)
(* Broadcast                                    *)
(* ============================================ *)

(** Notification callback: invoked after a successful broadcast with the
    mention target (if any). Set by Keeper bootstrap to wire up wakeup. *)
let on_broadcast_mention : (string option -> unit) ref =
  ref (fun _mention -> ())

let broadcast ?trace_context config ~from_agent ~content =
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
    trace_context;
  } in
  let msg_file =
    Filename.concat (messages_dir config)
      (Printf.sprintf "%09d_%s_broadcast.json" seq (safe_filename from_agent))
  in
  write_json config msg_file (message_to_yojson msg);
  (match backend_publish config ~channel:(broadcast_channel config)
      ~message:(Yojson.Safe.to_string (message_to_yojson msg)) with
   | Ok _ -> ()
   | Error (Backend_types.BackendNotSupported msg) when String.starts_with ~prefix:"FileSystem backend" msg ->
       Log.Misc.debug "broadcast publish skipped: %s" msg
   | Error e -> Log.Misc.error "broadcast publish failed: %s" (Backend_types.show_error e));
  emit_message_activity config ~from_agent:safe_agent ~content:safe_content
    ~mention ();
  (try !on_broadcast_mention mention
   with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
     Log.Misc.warn "on_broadcast_mention callback failed: %s"
       (Printexc.to_string exn));
  Printf.sprintf "📢 [%s] %s" safe_agent safe_content

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
