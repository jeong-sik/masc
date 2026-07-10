(** MASC gRPC Workspace Masc_domain.

    Wire format: protobuf binary over gRPC framing.
    Types are generated from proto/masc_workspace.proto via ocaml-protoc-plugin.

    Each message provides [to_bytes] and [of_bytes] for both server
    (request decode + response encode) and client (request encode +
    response decode) usage. *)

(** {1 Shared Types} *)

type agent_info =
  { name : string
  ; status : string
  ; capabilities : string list
  ; last_seen_ms : int64
  ; session_bound_at_ms : int64
  ; current_task_id : string
  }

type task_info =
  { id : string
  ; title : string
  ; status : string
  ; assigned_to : string
  ; priority : int
  }

(** {1 Heartbeat} *)

module HeartbeatPing : sig
  type t =
    { agent_name : string
    ; session_id : string
    ; timestamp_ms : int64
    ; current_task_id : string
    ; auth_token : string
    }

  val of_bytes_result : string -> (t, string) result
  val of_bytes : string -> t
  val to_bytes : t -> string
end

module HeartbeatAck : sig
  type t =
    { timestamp_ms : int64
    ; active_agent_count : int
    ; pending_task_count : int
    }

  val of_bytes : string -> t
  val to_bytes : t -> string
end

(** {1 Event Subscription} *)

module SubscribeRequest : sig
  type t =
    { agent_name : string
    ; session_id : string
    ; event_types : string list
    ; since_seq : int64
    ; auth_token : string
    }

  val of_bytes_result : string -> (t, string) result
  val of_bytes : string -> t
end

(** Client-side serialization for SubscribeRequest. *)
module SubscribeRequest_serde : sig
  val to_bytes : SubscribeRequest.t -> string
end

module Event : sig
  type t =
    { seq : int64
    ; event_type : string
    ; source_agent : string
    ; timestamp_ms : int64
    ; payload_json : string
    }

  val of_bytes : string -> t
  val to_bytes : t -> string
end

(** {1 Tool Call} *)

module ToolCallRequest : sig
  type t =
    { agent_name : string
    ; session_id : string
    ; tool_name : string
    ; arguments_json : string
    ; auth_token : string
    }

  val of_bytes_result : string -> (t, string) result
  val of_bytes : string -> t
  val to_bytes : t -> string
end

module ToolCallResponse : sig
  type t =
    { success : bool
    ; result_json : string
    ; error_message : string
    ; error_code : int
    }

  val of_bytes : string -> t
  val to_bytes : t -> string
end

(** {1 Broadcast} *)

module BroadcastRequest : sig
  type t =
    { agent_name : string
    ; message : string
    ; mentions : string list
    ; auth_token : string
    }

  val of_bytes_result : string -> (t, string) result
  val of_bytes : string -> t
  val to_bytes : t -> string
end

module BroadcastResponse : sig
  type t =
    { success : bool
    ; seq : int64
    }

  val of_bytes : string -> t
  val to_bytes : t -> string
end

(** {1 Status} *)

module StatusRequest : sig
  type t = { auth_token : string }

  val of_bytes_result : string -> (t, string) result
  val of_bytes : string -> t
  val to_bytes : t -> string
end

module StatusResponse : sig
  type t =
    { agents : agent_info list
    ; tasks : task_info list
    ; message_count : int
    ; workspace_path : string
    }

  val of_bytes : string -> t
  val to_bytes : t -> string
end
