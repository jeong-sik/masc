(** MASC gRPC Coordination Masc_domain.

    Wire format: protobuf binary over gRPC framing.
    Types are generated from proto/masc_coordination.proto via ocaml-protoc-plugin.

    Each message provides [to_bytes] and [of_bytes] for both server
    (request decode + response encode) and client (request encode +
    response decode) usage. *)

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

(** {1 Agent Lifecycle} *)

module JoinRequest : sig
  type t = {
    agent_name : string;
    capabilities : string list;
    metadata : (string * string) list;
  }
  val of_bytes_result : string -> (t, string) result
  val of_bytes : string -> t
  val to_bytes : t -> string
end

module JoinResponse : sig
  type t = {
    success : bool;
    message : string;
    session_id : string;
    active_agents : agent_info list;
  }
  val of_bytes : string -> t
  val to_bytes : t -> string
end

module LeaveRequest : sig
  type t = {
    agent_name : string;
    session_id : string;
  }
  val of_bytes_result : string -> (t, string) result
  val of_bytes : string -> t
  val to_bytes : t -> string
end

module LeaveResponse : sig
  type t = {
    success : bool;
    message : string;
  }
  val of_bytes : string -> t
  val to_bytes : t -> string
end

(** {1 Heartbeat} *)

module HeartbeatPing : sig
  type t = {
    agent_name : string;
    session_id : string;
    timestamp_ms : int64;
    current_task_id : string;
  }
  val of_bytes_result : string -> (t, string) result
  val of_bytes : string -> t
  val to_bytes : t -> string
end

module HeartbeatAck : sig
  type t = {
    timestamp_ms : int64;
    active_agent_count : int;
    pending_task_count : int;
    directives : string list;
  }
  val of_bytes : string -> t
  val to_bytes : t -> string
end

(** {1 Event Subscription} *)

module SubscribeRequest : sig
  type t = {
    agent_name : string;
    session_id : string;
    event_types : string list;
    since_seq : int64;
  }
  val of_bytes_result : string -> (t, string) result
  val of_bytes : string -> t
end

(** Client-side serialization for SubscribeRequest. *)
module SubscribeRequest_serde : sig
  val to_bytes : SubscribeRequest.t -> string
end

module Event : sig
  type t = {
    seq : int64;
    event_type : string;
    source_agent : string;
    timestamp_ms : int64;
    payload_json : string;
  }
  val of_bytes : string -> t
  val to_bytes : t -> string
end

(** {1 Tool Call} *)

module ToolCallRequest : sig
  type t = {
    agent_name : string;
    session_id : string;
    tool_name : string;
    arguments_json : string;
  }
  val of_bytes_result : string -> (t, string) result
  val of_bytes : string -> t
  val to_bytes : t -> string
end

module ToolCallResponse : sig
  type t = {
    success : bool;
    result_json : string;
    error_message : string;
    error_code : int;
  }
  val of_bytes : string -> t
  val to_bytes : t -> string
end

(** {1 Broadcast} *)

module BroadcastRequest : sig
  type t = {
    agent_name : string;
    message : string;
    mentions : string list;
  }
  val of_bytes_result : string -> (t, string) result
  val of_bytes : string -> t
  val to_bytes : t -> string
end

module BroadcastResponse : sig
  type t = {
    success : bool;
    seq : int64;
  }
  val of_bytes : string -> t
  val to_bytes : t -> string
end

(** {1 Status} *)

module StatusResponse : sig
  type t = {
    agents : agent_info list;
    tasks : task_info list;
    message_count : int;
    room_path : string;
  }
  val of_bytes : string -> t
  val to_bytes : t -> string
end
