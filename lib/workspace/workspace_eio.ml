(** Workspace_eio: OCaml 5.x Eio-native Workspace implementation

    Direct-style async I/O using Eio.

    This module provides workspace primitives for multi-agent systems:
    - Agent registration/heartbeat
    - File locking
    - Message broadcasting
    - Task management

    Migration path: Workspace -> Workspace_eio
*)

open Result.Syntax

(** {1 Types} *)

(** Workspace configuration for Eio backend *)
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

(** Workspace state *)
type workspace_state = {
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

(** Convert a backend error to a human-readable string for result payloads.
    Kept private to this module because different call sites want different
    prefixes/special cases. *)
let backend_error_to_string = function
  | Backend.IOError m -> m
  | Backend.NotFound k -> "Not found: " ^ k
  | Backend.AlreadyExists k -> "Already exists: " ^ k
  | Backend.InvalidKey k -> "Invalid key: " ^ k
  | Backend.ConnectionFailed m -> "Connection failed: " ^ m
  | Backend.BackendNotSupported m -> "Not supported: " ^ m

(** [json_decode f] runs [f ()] and turns any raised exception into an
    [Error (Printexc.to_string exn)], preserving the original
    [Eio.Cancel.Cancelled] re-raise behaviour. *)
let json_decode f =
  try Ok (f ()) with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

(** {1 Configuration} *)

(** Create Eio-native workspace configuration *)
let create_config ~fs ?clock base_path =
  let backend_config = Backend.{
    base_path = Common.masc_dir_from_base_path ~base_path;
    node_id = Printf.sprintf "node_%d" (Unix.getpid ());
    cluster_name = "default";
    pubsub_max_messages = Backend.pubsub_max_messages;
  } in
  let backend = Backend.FileSystem.create ~fs ?clock backend_config in
  (* Otel_metric_store mutex observers are installed from lib/otel_metric_store.ml so
     this extracted workspace library does not depend on the top-level
     Otel_metric_store module. *)
  {
    base_path;
    lock_expiry_minutes = 30;
    backend;
    fs;
  }

(** Create test configuration (isolated) *)
let test_config ~fs base_path =
  let backend_config = Backend.{
    base_path = Common.masc_dir_from_base_path ~base_path;
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
  | AgentSessionBound
  | AgentSessionEnded
  | Broadcast
  | LockAcquire
  | LockRelease

let event_type_to_string = function
  | AgentSessionBound -> "agent_session_bound"
  | AgentSessionEnded -> "agent_session_ended"
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
       let msg = backend_error_to_string e in
       Log.Workspace.warn "append_event set failed for seq %d: %s" seq msg);
  event

(** Get event by sequence *)
let get_event_result config ~seq =
  match Backend.FileSystem.get config.backend (event_key seq) with
  | Ok json_str ->
    (match
       Safe_ops.parse_json_safe
         ~context:(Printf.sprintf "workspace_event:%d" seq)
         json_str
     with
     | Ok json -> Ok (Some json)
     | Error err -> Error err)
  | Error (Backend.NotFound _) -> Ok None
  | Error err -> Error (backend_error_to_string err)

(** Compatibility wrapper around [get_event_result]. *)
let get_event config ~seq =
  match get_event_result config ~seq with
  | Ok event -> event
  | Error err ->
    Log.Workspace.warn "get_event failed for seq %d: %s" seq err;
    None

(** Get recent events
    Uses atomic_get for cross-process safe counter read. *)
let get_recent_events config ~limit =
  let current_seq = match Backend.FileSystem.atomic_get config.backend event_seq_key with
    | Ok n -> n
    | Error (Backend.NotFound _) -> 0
    | Error (Backend.IOError m) ->
        Log.Workspace.warn "get_recent_events: event seq read failed: %s" m;
        0
    | Error (Backend.AlreadyExists _ | Backend.InvalidKey _
            | Backend.ConnectionFailed _ | Backend.BackendNotSupported _) ->
        Log.Workspace.warn "get_recent_events: event seq read failed: %s"
          "unexpected backend error";
        0
  in
  let start_seq = max 0 (current_seq - limit) in
  let rec collect acc seq =
    if seq >= current_seq then List.rev acc
    else match get_event_result config ~seq with
      | Ok (Some ev) -> collect (ev :: acc) (seq + 1)
      | Ok None -> collect acc (seq + 1)
      | Error err ->
        Log.Workspace.warn "get_recent_events: event read failed seq %d: %s" seq err;
        collect acc (seq + 1)
  in
  collect [] start_seq

(** {1 State Management} *)

let default_workspace_state () = {
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

let workspace_state_to_json state =
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

let workspace_state_of_json json =
  let m key = Option.value ~default:`Null (Json_util.assoc_member_opt key json) in
  json_decode (fun () ->
    {
      protocol_version = (match m "protocol_version" with `String s -> s | _ -> raise (Invalid_argument "protocol_version"));
      started_at = (match m "started_at" with `Float f -> f | `Int i -> float_of_int i | _ -> raise (Invalid_argument "started_at"));
      last_updated = (match m "last_updated" with `Float f -> f | `Int i -> float_of_int i | _ -> raise (Invalid_argument "last_updated"));
      active_agents = (match m "active_agents" with `List items -> List.filter_map (function `String s -> Some s | _ -> None) items | _ -> []);
      message_seq = (match m "message_seq" with `Int i -> i | _ -> 0);
      (* Backward compat: default to 0 if event_seq missing from old state files *)
      event_seq = Safe_ops.json_int ~default:0 "event_seq" json;
      mode = (match m "mode" with `String s -> s | _ -> "");
      paused = (match m "paused" with `Bool b -> b | _ -> false);
      paused_by = Json_util.get_string json "paused_by";
      paused_at = Json_util.get_float json "paused_at";
      pause_reason = Json_util.get_string json "pause_reason";
    })

(** Read workspace state *)
let read_state config =
  match Backend.FileSystem.get config.backend state_key with
  | Ok json_str ->
      json_decode (fun () ->
        let json = Yojson.Safe.from_string json_str in
        match workspace_state_of_json json with
        | Ok s -> s
        | Error e -> raise (Invalid_argument e))
  | Error (Backend.NotFound _) ->
      Ok (default_workspace_state ())
  | Error (Backend.IOError msg) -> Error msg
  | Error (Backend.AlreadyExists k) -> Error ("Already exists: " ^ k)
  | Error (Backend.InvalidKey k) -> Error ("Invalid key: " ^ k)
  | Error (Backend.ConnectionFailed m) -> Error ("Connection failed: " ^ m)
  | Error (Backend.BackendNotSupported m) -> Error ("Not supported: " ^ m)

(** Write workspace state *)
let write_state config state =
  let state = { state with last_updated = Time_compat.now () } in
  let json_str = Yojson.Safe.to_string (workspace_state_to_json state) in
  Backend.FileSystem.set config.backend state_key json_str

(** Atomically update workspace state with a transform function.
    This is safe for multiple processes accessing the same state file.
    The transform receives current state (or default if not exists) and returns new state.
    Returns [Ok new_state] on success.
*)
let atomic_update_state config ~f =
  Atomic.incr state_update_attempts;
  let transform json_opt =
    let current_state =
      match json_opt with
      | None -> default_workspace_state ()
      | Some json_str ->
          (try
            let json = Yojson.Safe.from_string json_str in
            match workspace_state_of_json json with
            | Ok s -> s
            | Error e ->
                Log.Workspace.warn "update_state: state deserialization failed, resetting: %s" e;
                default_workspace_state ()
          with Eio.Io _ | Yojson.Json_error _ -> default_workspace_state ())
    in
    let new_state = f current_state in
    let new_state = { new_state with last_updated = Time_compat.now () } in
    Yojson.Safe.to_string (workspace_state_to_json new_state)
  in
  match Backend.FileSystem.atomic_update config.backend state_key ~f:transform with
  | Ok json_str ->
      json_decode (fun () ->
        let json = Yojson.Safe.from_string json_str in
        match workspace_state_of_json json with
        | Ok s -> s
        | Error e -> raise (Invalid_argument e))
  | Error e ->
      Atomic.incr state_update_failures;
      Error (backend_error_to_string e)

(** {1 Agent Operations} *)

let agent_state_to_json agent =
  `Assoc [
    ("name", `String agent.name);
    ("last_seen", `Float agent.last_seen);
    ("capabilities", `List (List.map (fun s -> `String s) agent.capabilities));
    ("status", `String agent.status);
  ]

let agent_state_of_json json =
  let m key = Option.value ~default:`Null (Json_util.assoc_member_opt key json) in
  json_decode (fun () ->
    {
      name = (match m "name" with `String s -> s | _ -> raise (Invalid_argument "name"));
      last_seen = (match m "last_seen" with `Float f -> f | `Int i -> float_of_int i | _ -> raise (Invalid_argument "last_seen"));
      capabilities = (match m "capabilities" with `List items -> List.filter_map (function `String s -> Some s | _ -> None) items | _ -> []);
      status = (match m "status" with `String s -> s | _ -> raise (Invalid_argument "status"));
    })

(** Register agent or update heartbeat

    Automatically subscribes to Messages for A2A communication.
    This ensures all agents can receive broadcasts immediately after joining.
    If the agent is already active, updates heartbeat without emitting AgentSessionBound.
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
  let* () =
    match Backend.FileSystem.set config.backend (agent_key name) json_str with
    | Ok () -> Ok ()
    | Error (Backend.IOError msg) -> Error msg
    | Error (Backend.NotFound _ | Backend.AlreadyExists _ | Backend.InvalidKey _
            | Backend.ConnectionFailed _ | Backend.BackendNotSupported _) ->
        Error "Failed to register agent"
  in
  (* Atomically update workspace state to include this agent *)
  (match atomic_update_state config ~f:(fun state ->
     let active_agents =
       if List.mem name state.active_agents then state.active_agents
       else name :: state.active_agents
     in
     { state with active_agents }
   ) with
  | Ok _ -> ()
  | Error msg -> Log.Workspace.warn "join_agent: state update failed for %s: %s" name msg);

  (* Auto-subscribe to Messages for A2A communication (via hook) *)
  (Atomic.get Workspace_hooks.subscribe_messages_fn) ~subscriber:name;

  (* Log join event only for new agents, skip for re-joins *)
  if not already_active then begin
    let _event = log_event config
      ~event_type:AgentSessionBound
      ~agent:name
      ~payload:(`Assoc [
        ("capabilities", `List (List.map (fun c -> `String c) capabilities))
      ]) in
    ()
  end;

  Ok agent

(** Get agent state *)
let get_agent config ~name =
  let* json_str =
    Backend.FileSystem.get config.backend (agent_key name)
    |> Result.map_error (function
        | Backend.NotFound _ -> "Agent not found"
        | Backend.IOError msg -> msg
        | Backend.AlreadyExists _ | Backend.InvalidKey _
        | Backend.ConnectionFailed _ | Backend.BackendNotSupported _ ->
            "Failed to get agent")
  in
  json_decode (fun () ->
    let json = Yojson.Safe.from_string json_str in
    match agent_state_of_json json with
    | Ok s -> s
    | Error e -> raise (Invalid_argument e))

(** Remove agent *)
let remove_agent config ~name =
  let* removed =
    match Backend.FileSystem.delete config.backend (agent_key name) with
    | Ok () -> Ok true
    | Error (Backend.NotFound _) -> Ok false  (* Already removed *)
    | Error (Backend.IOError msg) -> Error msg
    | Error (Backend.AlreadyExists _ | Backend.InvalidKey _
            | Backend.ConnectionFailed _ | Backend.BackendNotSupported _) ->
        Error "Failed to remove agent"
  in
  if removed then begin
    (* Atomically update workspace state to remove this agent *)
    (match atomic_update_state config ~f:(fun state ->
       let active_agents = List.filter (fun n -> n <> name) state.active_agents in
       { state with active_agents }
     ) with
    | Ok _ -> ()
    | Error msg -> Log.Workspace.warn "remove_agent: state update failed for %s: %s" name msg);

    (* Log leave event *)
    let _event = log_event config
      ~event_type:AgentSessionEnded
      ~agent:name
      ~payload:`Null in
    ()
  end;

  Ok ()

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
  let m key = Option.value ~default:`Null (Json_util.assoc_member_opt key json) in
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
    let resource_opt = parse_string (m "resource") in
    let owner_opt = parse_string (m "owner") in
    let acquired_at_opt = parse_float (m "acquired_at") in
    let expires_at_opt = parse_float (m "expires_at") in
    match resource_opt, owner_opt, acquired_at_opt, expires_at_opt with
    | Some resource, Some owner, Some acquired_at, Some expires_at ->
        Ok { resource; owner; acquired_at; expires_at }
    | _ ->
        (* Previously collapsed to the bare "Invalid lock metadata".
           Operators reading a recover/repair log line cannot tell
           which of the four fields the lock JSON was missing; that
           detail is what the producer-side fix needs.  Enumerate
           which field(s) failed to parse so the message carries the
           same information the parser already has in scope. *)
        let missing =
          List.filter_map (fun (name, opt) ->
            if Option.is_none opt then Some name else None)
            [ ("resource (string)", Option.map (fun _ -> ()) resource_opt);
              ("owner (string)", Option.map (fun _ -> ()) owner_opt);
              ("acquired_at (number)",
               Option.map (fun _ -> ()) acquired_at_opt);
              ("expires_at (number)",
               Option.map (fun _ -> ()) expires_at_opt);
            ]
        in
        Error
          (Printf.sprintf
             "Invalid lock metadata: missing or wrong-type field(s) [%s]"
             (String.concat ", " missing))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

(** Acquire lock on a resource *)
let acquire_lock config ~resource ~owner =
  let ttl_seconds = config.lock_expiry_minutes * 60 in
  let+ acquired =
    Backend.FileSystem.acquire_lock config.backend
      ~key:resource ~owner ~ttl_seconds
    |> Result.map_error (function
        | Backend.IOError msg -> msg
        | Backend.NotFound _ | Backend.AlreadyExists _ | Backend.InvalidKey _
        | Backend.ConnectionFailed _ | Backend.BackendNotSupported _ ->
            "Failed to acquire lock")
  in
  if acquired then
    Some {
      resource;
      owner;
      acquired_at = Time_compat.now ();
      expires_at = Time_compat.now () +. float_of_int ttl_seconds;
    }
  else
    None  (* Lock held by someone else *)

(** Release lock *)
let release_lock config ~resource ~owner =
  let* released =
    Backend.FileSystem.release_lock config.backend ~key:resource ~owner
    |> Result.map_error (function
        | Backend.IOError msg -> msg
        | Backend.NotFound _ | Backend.AlreadyExists _ | Backend.InvalidKey _
        | Backend.ConnectionFailed _ | Backend.BackendNotSupported _ ->
            "Failed to release lock")
  in
  if released then Ok () else Error "Not lock owner"

(** Extend lock TTL *)
let extend_lock config ~resource ~owner =
  let* extended =
    Backend.FileSystem.extend_lock config.backend
      ~key:resource ~owner ~ttl_seconds:(config.lock_expiry_minutes * 60)
    |> Result.map_error (function
        | Backend.IOError msg -> msg
        | Backend.NotFound _ | Backend.AlreadyExists _ | Backend.InvalidKey _
        | Backend.ConnectionFailed _ | Backend.BackendNotSupported _ ->
            "Failed to extend lock")
  in
  if extended then Ok () else Error "Not lock owner or lock expired"

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
  let m key = Option.value ~default:`Null (Json_util.assoc_member_opt key json) in
  json_decode (fun () ->
    {
      seq = (match m "seq" with `Int i -> i | _ -> raise (Invalid_argument "seq"));
      from_agent = (match m "from" with `String s -> s | _ -> raise (Invalid_argument "from"));
      content = (match m "content" with `String s -> s | _ -> raise (Invalid_argument "content"));
      mention = Json_util.get_string json "mention";
      timestamp = (match m "timestamp" with `Float f -> f | `Int i -> float_of_int i | _ -> raise (Invalid_argument "timestamp"));
    })

(** Extract @mention from message content
    Uses Mention module for Stateless/Stateful/Broadcast parsing *)
let extract_mention content =
  Mention.extract content

(** Key for atomic message sequence counter *)
let message_seq_key = "counters:message_seq"

(** Broadcast message to workspace

    Uses file-based atomic_increment for cross-process safety.
    Ensures unique seq even under concurrent broadcasts from multiple processes.
*)
(** SSOT: [on_broadcast_mention] is defined in [Workspace_broadcast].
    We delegate to it here instead of maintaining a separate ref. *)

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
  let* () =
    match Backend.FileSystem.set config.backend (message_key seq) json_str with
    | Ok () -> Ok ()
    | Error (Backend.IOError msg) -> Error msg
    | Error (Backend.NotFound _ | Backend.AlreadyExists _ | Backend.InvalidKey _
            | Backend.ConnectionFailed _ | Backend.BackendNotSupported _) ->
        Error "Failed to broadcast message"
  in
  (* Atomically update state's message_seq for consistency *)
  (match atomic_update_state config ~f:(fun state ->
     { state with message_seq = seq }
   ) with
  | Ok _ -> ()
  | Error msg -> Log.Workspace.warn "broadcast: state update failed for seq %d: %s" seq msg);

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
  (try !Workspace_broadcast.on_broadcast_mention msg.mention
   with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
     Log.Workspace.warn "on_broadcast_mention callback failed: %s"
       (Printexc.to_string exn));
  Ok msg

(** Get message by sequence number *)
let get_message config ~seq =
  let* json_str =
    Backend.FileSystem.get config.backend (message_key seq)
    |> Result.map_error (function
        | Backend.NotFound _ -> "Message not found"
        | Backend.IOError msg -> msg
        | Backend.AlreadyExists _ | Backend.InvalidKey _
        | Backend.ConnectionFailed _ | Backend.BackendNotSupported _ ->
            "Failed to get message")
  in
  json_decode (fun () ->
    let json = Yojson.Safe.from_string json_str in
    match message_of_json json with
    | Ok s -> s
    | Error e -> raise (Invalid_argument e))

(** {1 Health Check} *)

let health_check config =
  Backend.FileSystem.health_check config.backend
  |> Result.map_error (function
      | Backend.IOError msg -> msg
      | Backend.NotFound _ | Backend.AlreadyExists _ | Backend.InvalidKey _
      | Backend.ConnectionFailed _ | Backend.BackendNotSupported _ ->
          "Health check failed")

(** {1 Workspace Status} *)

let status config =
  match read_state config with
  | Ok state ->
      `Assoc [
        ("protocol_version", `String state.protocol_version);
        ("started_at", `String (now_iso ()));
        ("active_agents", `List (List.map (fun s -> `String s) state.active_agents));
        ("message_count", `Int state.message_seq);
        ("mode", `String state.mode);
        ("paused", `Bool state.paused);
      ]
  | Error e ->
      `Assoc [("error", `String e)]
