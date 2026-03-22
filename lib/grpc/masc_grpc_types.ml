(** MASC gRPC Coordination Types.

    Wire format: JSON-encoded strings over gRPC framing.
    This avoids a protobuf codegen dependency while keeping the proto file
    as the canonical API contract.

    Each message type provides [to_bytes] and [of_bytes] for the
    grpc-direct handler interface (string -> string). *)

(** {1 Shared Types} *)

type agent_info = {
  name : string;
  status : string;
  capabilities : string list;
  last_heartbeat_ms : int64;
  joined_at_ms : int64;
  current_task_id : string;
}

type task_info = {
  id : string;
  title : string;
  status : string;
  assigned_to : string;
  priority : int;
}

(** {1 JSON Helpers} *)

let string_of_json key json =
  match json with
  | `Assoc fields -> (
    match List.assoc_opt key fields with
    | Some (`String s) -> s
    | _ -> "")
  | _ -> ""

let string_list_of_json key json =
  match json with
  | `Assoc fields -> (
    match List.assoc_opt key fields with
    | Some (`List items) ->
      List.filter_map (function `String s -> Some s | _ -> None) items
    | _ -> [])
  | _ -> []

let int64_of_json key json =
  match json with
  | `Assoc fields -> (
    match List.assoc_opt key fields with
    | Some (`Int n) -> Int64.of_int n
    | Some (`Intlit s) -> (
      match Int64.of_string_opt s with Some n -> n | None -> 0L)
    | _ -> 0L)
  | _ -> 0L

let string_map_of_json key json =
  match json with
  | `Assoc fields -> (
    match List.assoc_opt key fields with
    | Some (`Assoc pairs) ->
      List.filter_map (fun (k, v) ->
        match v with `String s -> Some (k, s) | _ -> None) pairs
    | _ -> [])
  | _ -> []

(** {1 Agent Lifecycle} *)

module JoinRequest = struct
  type t = {
    agent_name : string;
    capabilities : string list;
    metadata : (string * string) list;
  }

  let of_bytes bytes =
    let json = Yojson.Safe.from_string bytes in
    {
      agent_name = string_of_json "agent_name" json;
      capabilities = string_list_of_json "capabilities" json;
      metadata = string_map_of_json "metadata" json;
    }

  let to_bytes t =
    `Assoc [
      ("agent_name", `String t.agent_name);
      ("capabilities", `List (List.map (fun s -> `String s) t.capabilities));
      ("metadata", `Assoc (List.map (fun (k, v) -> (k, `String v)) t.metadata));
    ]
    |> Yojson.Safe.to_string
end

let agent_info_to_json (a : agent_info) : Yojson.Safe.t =
  `Assoc [
    ("name", `String a.name);
    ("status", `String a.status);
    ("capabilities", `List (List.map (fun s -> `String s) a.capabilities));
    ("last_heartbeat_ms", `Intlit (Int64.to_string a.last_heartbeat_ms));
    ("joined_at_ms", `Intlit (Int64.to_string a.joined_at_ms));
    ("current_task_id", `String a.current_task_id);
  ]

module JoinResponse = struct
  type t = {
    success : bool;
    message : string;
    session_id : string;
    active_agents : agent_info list;
  }

  let to_bytes t =
    `Assoc [
      ("success", `Bool t.success);
      ("message", `String t.message);
      ("session_id", `String t.session_id);
      ("active_agents", `List (List.map agent_info_to_json t.active_agents));
    ]
    |> Yojson.Safe.to_string
end

module LeaveRequest = struct
  type t = {
    agent_name : string;
    session_id : string;
  }

  let of_bytes bytes =
    let json = Yojson.Safe.from_string bytes in
    {
      agent_name = string_of_json "agent_name" json;
      session_id = string_of_json "session_id" json;
    }

  let to_bytes t =
    `Assoc [
      ("agent_name", `String t.agent_name);
      ("session_id", `String t.session_id);
    ]
    |> Yojson.Safe.to_string
end

module LeaveResponse = struct
  type t = {
    success : bool;
    message : string;
  }

  let to_bytes t =
    `Assoc [
      ("success", `Bool t.success);
      ("message", `String t.message);
    ]
    |> Yojson.Safe.to_string
end

(** {1 Heartbeat} *)

module HeartbeatPing = struct
  type t = {
    agent_name : string;
    session_id : string;
    timestamp_ms : int64;
    current_task_id : string;
  }

  let of_bytes bytes =
    let json = Yojson.Safe.from_string bytes in
    {
      agent_name = string_of_json "agent_name" json;
      session_id = string_of_json "session_id" json;
      timestamp_ms = int64_of_json "timestamp_ms" json;
      current_task_id = string_of_json "current_task_id" json;
    }
end

module HeartbeatAck = struct
  type t = {
    timestamp_ms : int64;
    active_agent_count : int;
    pending_task_count : int;
    directives : string list;
  }

  let to_bytes t =
    `Assoc [
      ("timestamp_ms", `Intlit (Int64.to_string t.timestamp_ms));
      ("active_agent_count", `Int t.active_agent_count);
      ("pending_task_count", `Int t.pending_task_count);
      ("directives", `List (List.map (fun s -> `String s) t.directives));
    ]
    |> Yojson.Safe.to_string
end

(** {1 Event Subscription} *)

module SubscribeRequest = struct
  type t = {
    agent_name : string;
    session_id : string;
    event_types : string list;
    since_seq : int64;
  }

  let of_bytes bytes =
    let json = Yojson.Safe.from_string bytes in
    {
      agent_name = string_of_json "agent_name" json;
      session_id = string_of_json "session_id" json;
      event_types = string_list_of_json "event_types" json;
      since_seq = int64_of_json "since_seq" json;
    }
end

module Event = struct
  type t = {
    seq : int64;
    event_type : string;
    source_agent : string;
    timestamp_ms : int64;
    payload_json : string;
  }

  let to_bytes t =
    `Assoc [
      ("seq", `Intlit (Int64.to_string t.seq));
      ("event_type", `String t.event_type);
      ("source_agent", `String t.source_agent);
      ("timestamp_ms", `Intlit (Int64.to_string t.timestamp_ms));
      ("payload_json", `String t.payload_json);
    ]
    |> Yojson.Safe.to_string
end

(** {1 Tool Call} *)

module ToolCallRequest = struct
  type t = {
    agent_name : string;
    session_id : string;
    tool_name : string;
    arguments_json : string;
  }

  let of_bytes bytes =
    let json = Yojson.Safe.from_string bytes in
    {
      agent_name = string_of_json "agent_name" json;
      session_id = string_of_json "session_id" json;
      tool_name = string_of_json "tool_name" json;
      arguments_json = string_of_json "arguments_json" json;
    }
end

module ToolCallResponse = struct
  type t = {
    success : bool;
    result_json : string;
    error_message : string;
    error_code : int;
  }

  let to_bytes t =
    `Assoc [
      ("success", `Bool t.success);
      ("result_json", `String t.result_json);
      ("error_message", `String t.error_message);
      ("error_code", `Int t.error_code);
    ]
    |> Yojson.Safe.to_string
end

(** {1 Broadcast} *)

module BroadcastRequest = struct
  type t = {
    agent_name : string;
    message : string;
    mentions : string list;
  }

  let of_bytes bytes =
    let json = Yojson.Safe.from_string bytes in
    {
      agent_name = string_of_json "agent_name" json;
      message = string_of_json "message" json;
      mentions = string_list_of_json "mentions" json;
    }
end

module BroadcastResponse = struct
  type t = {
    success : bool;
    seq : int64;
  }

  let to_bytes t =
    `Assoc [
      ("success", `Bool t.success);
      ("seq", `Intlit (Int64.to_string t.seq));
    ]
    |> Yojson.Safe.to_string
end

(** {1 Status} *)

let task_info_to_json (t : task_info) : Yojson.Safe.t =
  `Assoc [
    ("id", `String t.id);
    ("title", `String t.title);
    ("status", `String t.status);
    ("assigned_to", `String t.assigned_to);
    ("priority", `Int t.priority);
  ]

module StatusResponse = struct
  type t = {
    agents : agent_info list;
    tasks : task_info list;
    message_count : int;
    room_path : string;
  }

  let to_bytes t =
    `Assoc [
      ("agents", `List (List.map agent_info_to_json t.agents));
      ("tasks", `List (List.map task_info_to_json t.tasks));
      ("message_count", `Int t.message_count);
      ("room_path", `String t.room_path);
    ]
    |> Yojson.Safe.to_string
end
