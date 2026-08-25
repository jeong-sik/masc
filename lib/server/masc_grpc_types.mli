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
  ; last_heartbeat_ms : int64
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
    ; directives : Keeper_directive.t list
    }

  (** Exact codec for the protobuf [Directive] oneof. Each arm is one
      constructor of {!Keeper_directive}, so the wire cannot name a directive
      this type does not have. [`not_set] — a Directive message with no field
      set — is the one shape protobuf still admits and is an error here. *)
  type directive_wire =
    [ `Pause of bool
    | `Wakeup of bool
    | `Claim_task_id of string
    | `not_set
    ]

  val directive_of_wire : directive_wire -> (Keeper_directive.t, string) result
  val directive_to_wire : Keeper_directive.t -> directive_wire

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
    }

  val of_bytes_result : string -> (t, string) result
  val of_bytes : string -> t
  val to_bytes : t -> string
end

module BroadcastResponse : sig
  type delivery_status =
    | Delivery_passive
    | Delivery_accepted
    | Delivery_already_accepted
    | Delivery_pending
    | Delivery_deferred
    | Delivery_rejected
    | Delivery_not_persisted
    | Delivery_outcome_unknown

  type retry_disposition =
    | Retry_do_not_resend
    | Retry_allowed
    | Retry_outcome_unknown

  type workspace_persistence_status =
    | Workspace_persisted
    | Workspace_not_persisted
    | Workspace_persistence_unknown

  type t =
    { success : bool
    ; seq : int64
    ; request_id : string option
    ; delivery_status : delivery_status
    ; delivery_reason : string option
    ; workspace_persistence_status : workspace_persistence_status
    ; retry_disposition : retry_disposition
    }

  val of_bytes : string -> t
  val to_bytes : t -> string
end

(** {1 Status} *)

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

