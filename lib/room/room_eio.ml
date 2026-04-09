(** Room_eio: OCaml 5.x Eio-native Room implementation

    Direct-style async I/O using Eio.

    This module provides coordination primitives for multi-agent systems:
    - Agent registration/heartbeat
    - File locking
    - Message broadcasting
    - Task management

    Migration path: Room -> Room_eio
*)

(** {1 Types} *)

(** Room configuration for Eio backend *)
type config = {
  base_path: string;
  lock_expiry_minutes: int;
  backend: Backend.FileSystem.t;
  fs: Eio.Fs.dir_ty Eio.Path.t;
}

(** Agent state *)
type agent_state = {
  name: string;
  last_seen: float;
  capabilities: string list;
  status: string;
}

(** Room state *)
type room_state = {
  protocol_version: string;
  started_at: float;
  last_updated: float;
  active_agents: string list;
  message_seq: int;
  event_seq: int;  (* Persisted event counter for audit log *)
  mode: string;
  paused: bool;
  paused_by: string option;
  paused_at: float option;
  pause_reason: string option;
}

(** {1 Health Counters} *)

let state_update_attempts = Atomic.make 0
let state_update_failures = Atomic.make 0

let state_health_counters () =
  let attempts = Atomic.get state_update_attempts in
  let failures = Atomic.get state_update_failures in
  `Assoc [
    ("state_update_attempts", `Int attempts);
    ("state_update_failures", `Int failures);
    ("failure_rate",
      `Float (if attempts = 0 then 0.0
              else float_of_int failures /. float_of_int attempts));
  ]

(** {1 Helpers} *)

let now_iso () =
  let t = Time_compat.now () in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
    (int_of_float ((t -. floor t) *. 1000.))

(** {1 Configuration} *)

(** Create Eio-native room configuration *)
let create_config ~fs base_path =
  let backend_config = Backend.{
    backend_type = FileSystem;
    base_path = Filename.concat base_path ".masc";
    postgres_url = None;
    node_id = Printf.sprintf "node_%d" (Unix.getpid ());
    cluster_name = "default";
    pubsub_max_messages = Backend.pubsub_max_messages_from_env ();
  } in
  let backend = Backend.FileSystem.create ~fs backend_config in
  {
    base_path;
    lock_expiry_minutes = 30;
    backend;
    fs;
  }

(** Create test configuration (isolated) *)
let test_config ~fs base_path =
  let backend_config = Backend.{
    backend_type = FileSystem;
    base_path = Filename.concat base_path ".masc";
    postgres_url = None;
    node_id = Printf.sprintf "test_node_%04x" (Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFF);
    cluster_name = "test";
    pubsub_max_messages = 1000;
  } in
  let backend = Backend.FileSystem.create ~fs backend_config in
  {
    base_path;
    lock_expiry_minutes = 5;  (* Shorter for tests *)
    backend;
    fs;
  }

(** {1 Key Utilities} *)

let agents_key = "agents"
let messages_key = "messages"
let locks_key = "locks"
let state_key = "state"
let events_key = "events"

let agent_key name = Printf.sprintf "%s:%s" agents_key name
let message_key seq = Printf.sprintf "%s:%06d" messages_key seq
let lock_key resource = Printf.sprintf "%s:%s" locks_key resource
let event_key seq = Printf.sprintf "%s:%06d" events_key seq

(** {1 Event Log - Persistent Audit Trail} *)

(** Event types for audit logging *)
type event_type =
  | AgentJoin
  | AgentLeave
  | Broadcast
  | LockAcquire
  | LockRelease

let event_type_to_string = function
  | AgentJoin -> "agent_join"
  | AgentLeave -> "agent_leave"
  | Broadcast -> "broadcast"
  | LockAcquire -> "lock_acquire"
  | LockRelease -> "lock_release"

(** Event record *)
type event = {
  event_seq: int;
  event_type: event_type;
  agent: string;
  payload: Yojson.Safe.t;
  timestamp: float;
}

let event_to_json e =
  `Assoc [
    ("seq", `Int e.event_seq);
    ("type", `String (event_type_to_string e.event_type));
    ("agent", `String e.agent);
    ("payload", e.payload);
    ("timestamp", `Float e.timestamp);
    ("timestamp_iso", `String (now_iso ()));
  ]

(** Key for atomic event sequence counter *)
let event_seq_key = "counters:event_seq"

(** Log an event to persistent storage
    Uses file-based atomic_increment for cross-process safety. *)
let log_event config ~event_type ~agent ~payload =
  (* Atomic increment via file lock - safe for multiple processes *)
  let seq = match Backend.FileSystem.atomic_increment config.backend event_seq_key with
    | Ok n -> n - 1  (* atomic_increment returns NEW value, events are 0-indexed *)
    | Error _ -> int_of_float (Time_compat.now () *. 1000.) mod 100000
  in
  let event = {
    event_seq = seq;
    event_type;
    agent;
    payload;
    timestamp = Time_compat.now ();
  } in
  let json_str = Yojson.Safe.to_string (event_to_json event) in
  (match Backend.FileSystem.set config.backend (event_key seq) json_str with
   | Ok () -> ()
   | Error e ->
       let msg = match e with
         | Backend.IOError m -> m | Backend.NotFound k -> "not found: " ^ k
         | Backend.AlreadyExists k -> "already exists: " ^ k | Backend.InvalidKey k -> "invalid key: " ^ k
         | Backend.ConnectionFailed m -> "connection failed: " ^ m | Backend.BackendNotSupported m -> "not supported: " ^ m in
       Log.Room.warn "append_event set failed for seq %d: %s" seq msg);
  event

(** Get event by sequence *)
let get_event config ~seq =
  match Backend.FileSystem.get config.backend (event_key seq) with
  | Ok json_str -> Some (Yojson.Safe.from_string json_str)
  | Error _ -> None

(** Get recent events
    Uses atomic_get for cross-process safe counter read. *)
let get_recent_events config ~limit =
  let current_seq = match Backend.FileSystem.atomic_get config.backend event_seq_key with
    | Ok n -> n
    | Error (Backend.NotFound _) -> 0
    | Error e ->
        Log.Room.debug "get_recent_events: event seq read failed: %s"
          (match e with Backend.IOError m -> m
           | _ -> "unexpected backend error");
        0
  in
  let start_seq = max 0 (current_seq - limit) in
  let rec collect acc seq =
    if seq >= current_seq then List.rev acc
    else match get_event config ~seq with
      | Some ev -> collect (ev :: acc) (seq + 1)
      | None -> collect acc (seq + 1)
  in
  collect [] start_seq

(** {1 State Management} *)

let default_room_state () = {
  protocol_version = "1.0.0";
  started_at = Time_compat.now ();
  last_updated = Time_compat.now ();
  active_agents = [];
  message_seq = 0;
  event_seq = 0;
  mode = "collaborative";
  paused = false;
  paused_by = None;
  paused_at = None;
  pause_reason = None;
}

let room_state_to_json state =
  `Assoc [
    ("protocol_version", `String state.protocol_version);
    ("started_at", `Float state.started_at);
    ("last_updated", `Float state.last_updated);
    ("active_agents", `List (List.map (fun s -> `String s) state.active_agents));
    ("message_seq", `Int state.message_seq);
    ("event_seq", `Int state.event_seq);
    ("mode", `String state.mode);
    ("paused", `Bool state.paused);
    ("paused_by", Json_util.string_opt_to_json state.paused_by);
    ("paused_at", Json_util.float_opt_to_json state.paused_at);
    ("pause_reason", Json_util.string_opt_to_json state.pause_reason);
  ]

let room_state_of_json json =
  let open Yojson.Safe.Util in
  try
    Ok {
      protocol_version = json |> member "protocol_version" |> to_string;
      started_at = json |> member "started_at" |> to_float;
      last_updated = json |> member "last_updated" |> to_float;
      active_agents = json |> member "active_agents" |> to_list |> List.map to_string;
      message_seq = json |> member "message_seq" |> to_int;
      (* Backward compat: default to 0 if event_seq missing from old state files *)
      event_seq = Safe_ops.json_int ~default:0 "event_seq" json;
      mode = json |> member "mode" |> to_string;
      paused = json |> member "paused" |> to_bool;
      paused_by = json |> member "paused_by" |> to_string_option;
      paused_at = json |> member "paused_at" |> to_float_option;
      pause_reason = json |> member "pause_reason" |> to_string_option;
    }
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

(** Read room state *)
let read_state config =
  match Backend.FileSystem.get config.backend state_key with
  | Ok json_str ->
      (try
        let json = Yojson.Safe.from_string json_str in
        room_state_of_json json
      with Eio.Cancel.Cancelled _ as e -> raise e | e -> Error (Printexc.to_string e))
  | Error (Backend.NotFound _) ->
      Ok (default_room_state ())
  | Error e ->
      Error (match e with
        | Backend.IOError msg -> msg
        | Backend.NotFound k -> "Not found: " ^ k
        | Backend.AlreadyExists k -> "Already exists: " ^ k
        | Backend.InvalidKey k -> "Invalid key: " ^ k
        | Backend.ConnectionFailed m -> "Connection failed: " ^ m
        | Backend.BackendNotSupported m -> "Not supported: " ^ m)

(** Write room state *)
let write_state config state =
  let state = { state with last_updated = Time_compat.now () } in
  let json_str = Yojson.Safe.to_string (room_state_to_json state) in
  Backend.FileSystem.set config.backend state_key json_str

(** Atomically update room state with a transform function.
    This is safe for multiple processes accessing the same state file.
    The transform receives current state (or default if not exists) and returns new state.
    Returns [Ok new_state] on success.
*)
let atomic_update_state config ~f =
  Atomic.incr state_update_attempts;
  let transform json_opt =
    let current_state =
      match json_opt with
      | None -> default_room_state ()
      | Some json_str ->
          (try
            let json = Yojson.Safe.from_string json_str in
            match room_state_of_json json with
            | Ok s -> s
            | Error e ->
                Log.Room.warn "update_state: state deserialization failed, resetting: %s" e;
                default_room_state ()
          with Eio.Io _ | Yojson.Json_error _ -> default_room_state ())
    in
    let new_state = f current_state in
    let new_state = { new_state with last_updated = Time_compat.now () } in
    Yojson.Safe.to_string (room_state_to_json new_state)
  in
  match Backend.FileSystem.atomic_update config.backend state_key ~f:transform with
  | Ok json_str ->
      (try
        let json = Yojson.Safe.from_string json_str in
        room_state_of_json json
      with Eio.Cancel.Cancelled _ as e -> raise e | e -> Error (Printexc.to_string e))
  | Error e ->
      Atomic.incr state_update_failures;
      Error (match e with
        | Backend.IOError msg -> msg
        | Backend.NotFound k -> "Not found: " ^ k
        | Backend.AlreadyExists k -> "Already exists: " ^ k
        | Backend.InvalidKey k -> "Invalid key: " ^ k
        | Backend.ConnectionFailed m -> "Connection failed: " ^ m
        | Backend.BackendNotSupported m -> "Not supported: " ^ m)

(** {1 Agent Operations} *)

let agent_state_to_json agent =
  `Assoc [
    ("name", `String agent.name);
    ("last_seen", `Float agent.last_seen);
    ("capabilities", `List (List.map (fun s -> `String s) agent.capabilities));
    ("status", `String agent.status);
  ]

let agent_state_of_json json =
  let open Yojson.Safe.Util in
  try
    Ok {
      name = json |> member "name" |> to_string;
      last_seen = json |> member "last_seen" |> to_float;
      capabilities = json |> member "capabilities" |> to_list |> List.map to_string;
      status = json |> member "status" |> to_string;
    }
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

(** Register agent or update heartbeat

    Automatically subscribes to Messages for A2A communication.
    This ensures all agents can receive broadcasts immediately after joining.
    If the agent is already active, updates heartbeat without emitting AgentJoin.
*)
let register_agent config ~name ?(capabilities=[]) () =
  let already_active =
    match Backend.FileSystem.get config.backend (agent_key name) with
    | Ok _ -> true
    | Error _ -> false
  in
  let agent = {
    name;
    last_seen = Time_compat.now ();
    capabilities;
    status = "active";
  } in
  let json_str = Yojson.Safe.to_string (agent_state_to_json agent) in
  match Backend.FileSystem.set config.backend (agent_key name) json_str with
  | Ok () ->
      (* Atomically update room state to include this agent *)
      (match atomic_update_state config ~f:(fun state ->
        let active_agents =
          if List.mem name state.active_agents then state.active_agents
          else name :: state.active_agents
        in
        { state with active_agents }
      ) with
      | Ok _ -> ()
      | Error msg -> Log.Room.warn "join_agent: state update failed for %s: %s" name msg);

      (* Auto-subscribe to Messages for A2A communication (via hook) *)
      !Room_hooks.subscribe_messages_fn ~subscriber:name;

      (* Log join event only for new agents, skip for re-joins *)
      if not already_active then begin
        let _event = log_event config
          ~event_type:AgentJoin
          ~agent:name
          ~payload:(`Assoc [
            ("capabilities", `List (List.map (fun c -> `String c) capabilities))
          ]) in
        ()
      end;

      Ok agent
  | Error e ->
      Error (match e with
        | Backend.IOError msg -> msg
        | _ -> "Failed to register agent")

(** Get agent state *)
let get_agent config ~name =
  match Backend.FileSystem.get config.backend (agent_key name) with
  | Ok json_str ->
      (try
        let json = Yojson.Safe.from_string json_str in
        agent_state_of_json json
      with Eio.Cancel.Cancelled _ as e -> raise e | e -> Error (Printexc.to_string e))
  | Error (Backend.NotFound _) ->
      Error "Agent not found"
  | Error e ->
      Error (match e with
        | Backend.IOError msg -> msg
        | _ -> "Failed to get agent")

(** Remove agent *)
let remove_agent config ~name =
  match Backend.FileSystem.delete config.backend (agent_key name) with
  | Ok () ->
      (* Atomically update room state to remove this agent *)
      (match atomic_update_state config ~f:(fun state ->
        let active_agents = List.filter (fun n -> n <> name) state.active_agents in
        { state with active_agents }
      ) with
      | Ok _ -> ()
      | Error msg -> Log.Room.warn "remove_agent: state update failed for %s: %s" name msg);

      (* Log leave event *)
      let _event = log_event config
        ~event_type:AgentLeave
        ~agent:name
        ~payload:`Null in

      Ok ()
  | Error (Backend.NotFound _) ->
      Ok ()  (* Already removed *)
  | Error e ->
      Error (match e with
        | Backend.IOError msg -> msg
        | _ -> "Failed to remove agent")

(** {1 Lock Operations} *)

type lock_info = {
  resource: string;
  owner: string;
  acquired_at: float;
  expires_at: float;
}

let lock_info_to_json lock =
  `Assoc [
    ("resource", `String lock.resource);
    ("owner", `String lock.owner);
    ("acquired_at", `Float lock.acquired_at);
    ("expires_at", `Float lock.expires_at);
  ]

let lock_info_of_json json =
  let open Yojson.Safe.Util in
  try
    let parse_float = function
      | `Float f -> Some f
      | `Int i -> Some (float_of_int i)
      | `Intlit s -> float_of_string_opt s
      | `String s -> float_of_string_opt s
      | _ -> None
    in
    let parse_string = function
      | `String s -> Some s
      | _ -> None
    in
    match
      (parse_string (member "resource" json),
       parse_string (member "owner" json),
       parse_float (member "acquired_at" json),
       parse_float (member "expires_at" json))
    with
    | Some resource, Some owner, Some acquired_at, Some expires_at ->
        Ok { resource; owner; acquired_at; expires_at }
    | _ -> Error "Invalid lock metadata"
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

(** Acquire lock on a resource *)
let acquire_lock config ~resource ~owner =
  let ttl_seconds = config.lock_expiry_minutes * 60 in
  match Backend.FileSystem.acquire_lock config.backend
          ~key:resource ~owner ~ttl_seconds with
  | Ok true ->
      let lock = {
        resource;
        owner;
        acquired_at = Time_compat.now ();
        expires_at = Time_compat.now () +. float_of_int ttl_seconds;
      } in
      Ok (Some lock)
  | Ok false ->
      Ok None  (* Lock held by someone else *)
  | Error e ->
      Error (match e with
        | Backend.IOError msg -> msg
        | _ -> "Failed to acquire lock")

(** Release lock *)
let release_lock config ~resource ~owner =
  match Backend.FileSystem.release_lock config.backend ~key:resource ~owner with
  | Ok true -> Ok ()
  | Ok false -> Error "Not lock owner"
  | Error e ->
      Error (match e with
        | Backend.IOError msg -> msg
        | _ -> "Failed to release lock")

(** Extend lock TTL *)
let extend_lock config ~resource ~owner =
  let ttl_seconds = config.lock_expiry_minutes * 60 in
  match Backend.FileSystem.extend_lock config.backend
          ~key:resource ~owner ~ttl_seconds with
  | Ok true -> Ok ()
  | Ok false -> Error "Not lock owner or lock expired"
  | Error e ->
      Error (match e with
        | Backend.IOError msg -> msg
        | _ -> "Failed to extend lock")

(** {1 Message Operations} *)

type message = {
  seq: int;
  from_agent: string;
  content: string;
  mention: string option;
  timestamp: float;
}

let message_to_json msg =
  `Assoc [
    ("seq", `Int msg.seq);
    ("from", `String msg.from_agent);
    ("content", `String msg.content);
    ("mention", Json_util.string_opt_to_json msg.mention);
    ("timestamp", `Float msg.timestamp);
  ]

let message_of_json json =
  let open Yojson.Safe.Util in
  try
    Ok {
      seq = json |> member "seq" |> to_int;
      from_agent = json |> member "from" |> to_string;
      content = json |> member "content" |> to_string;
      mention = json |> member "mention" |> to_string_option;
      timestamp = json |> member "timestamp" |> to_float;
    }
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

(** Extract @mention from message content
    Uses Mention module for Stateless/Stateful/Broadcast parsing *)
let extract_mention content =
  Mention.extract content

(** Key for atomic message sequence counter *)
let message_seq_key = "counters:message_seq"

(** Broadcast message to room

    Uses file-based atomic_increment for cross-process safety.
    Ensures unique seq even under concurrent broadcasts from multiple processes.
*)
(** Notification callback: invoked after a successful broadcast with the
    mention target (if any). Set by Keeper bootstrap to wire up wakeup. *)
let on_broadcast_mention : (string option -> unit) ref =
  ref (fun _mention -> ())

let broadcast config ~from_agent ~content =
  (* Atomic increment via file lock - safe for multiple processes *)
  let seq = match Backend.FileSystem.atomic_increment config.backend message_seq_key with
    | Ok n -> n
    | Error _ ->
        (* Fallback: use timestamp-based unique seq (less reliable but won't fail) *)
        int_of_float (Time_compat.now () *. 1000000.) mod 1000000
  in
  let msg = {
    seq;
    from_agent;
    content;
    mention = extract_mention content;
    timestamp = Time_compat.now ();
  } in
  let json_str = Yojson.Safe.to_string (message_to_json msg) in
  match Backend.FileSystem.set config.backend (message_key seq) json_str with
  | Ok () ->
      (* Atomically update state's message_seq for consistency *)
      (match atomic_update_state config ~f:(fun state ->
        { state with message_seq = seq }
      ) with
      | Ok _ -> ()
      | Error msg -> Log.Room.warn "broadcast: state update failed for seq %d: %s" seq msg);

      (* Log broadcast event *)
      let _event = log_event config
        ~event_type:Broadcast
        ~agent:from_agent
        ~payload:(`Assoc [
          ("message_seq", `Int seq);
          ("mention", Json_util.string_opt_to_json msg.mention);
          ("content_preview", `String (String.sub content 0 (min 100 (String.length content))));
        ]) in

      (* Notify keepers about the mention *)
      (try !on_broadcast_mention msg.mention
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         Log.Room.warn "on_broadcast_mention callback failed: %s"
           (Printexc.to_string exn));
      Ok msg
  | Error e ->
      Error (match e with
        | Backend.IOError msg -> msg
        | _ -> "Failed to broadcast message")

(** Get message by sequence number *)
let get_message config ~seq =
  match Backend.FileSystem.get config.backend (message_key seq) with
  | Ok json_str ->
      (try
        let json = Yojson.Safe.from_string json_str in
        message_of_json json
      with Eio.Cancel.Cancelled _ as e -> raise e | e -> Error (Printexc.to_string e))
  | Error (Backend.NotFound _) ->
      Error "Message not found"
  | Error e ->
      Error (match e with
        | Backend.IOError msg -> msg
        | _ -> "Failed to get message")

(** {1 Health Check} *)

let health_check config =
  match Backend.FileSystem.health_check config.backend with
  | Ok result -> Ok result
  | Error e ->
      Error (match e with
        | Backend.IOError msg -> msg
        | _ -> "Health check failed")

(** {1 Room Status} *)

let status config =
  match read_state config with
  | Error e ->
      `Assoc [("error", `String e)]
  | Ok state ->
      `Assoc [
        ("protocol_version", `String state.protocol_version);
        ("started_at", `String (now_iso ()));
        ("active_agents", `List (List.map (fun s -> `String s) state.active_agents));
        ("message_count", `Int state.message_seq);
        ("mode", `String state.mode);
        ("paused", `Bool state.paused);
      ]
