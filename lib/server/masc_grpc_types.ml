(** MASC gRPC Workspace Masc_domain.

    Wire format: protobuf binary over gRPC framing.
    Types are generated from proto/masc_workspace.proto via ocaml-protoc-plugin.

    Each message type provides [to_bytes] and [of_bytes] for the
    grpc-direct handler interface (string -> string).

    The generated protobuf modules live under [Masc_proto.Masc_workspace.Masc.Workspace.V1]. *)

module P = Masc_proto.Masc_workspace.Masc.Workspace.V1

(** {1 Protobuf Serialization Helpers} *)

(** Serialize a protobuf message to a binary string. *)
let encode to_proto msg = Ocaml_protoc_plugin.Writer.contents (to_proto msg)

(** Deserialize a protobuf message from a binary string.

    [type_name] identifies the protobuf message type being decoded
    (e.g. "ToolCallResponse"). It is embedded in the
    error message so operators see which message type failed instead
    of a context-free "protobuf decode error: ..." line. *)
let decode_result ~type_name from_proto bytes =
  let reader = Ocaml_protoc_plugin.Reader.create bytes in
  match from_proto reader with
  | Ok v -> Ok v
  | Error e ->
    Error
      (Printf.sprintf
         "protobuf decode error: %s: %s"
         type_name
         (Ocaml_protoc_plugin.Result.show_error e))
;;

(** Deserialize a protobuf message from a binary string.
    Raises [Invalid_argument] on parse error. The exception payload
    includes [type_name] so the bare backtrace is operator-actionable. *)
let decode ~type_name from_proto bytes =
  match decode_result ~type_name from_proto bytes with
  | Ok v -> v
  | Error msg -> invalid_arg msg
;;

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

(** Convert our [agent_info] to a protobuf AgentInfo and back. *)
let agent_info_to_proto (a : agent_info) : P.AgentInfo.t =
  { name = a.name
  ; status = a.status
  ; capabilities = a.capabilities
  ; last_heartbeat_ms = a.last_heartbeat_ms
  ; session_bound_at_ms = a.session_bound_at_ms
  ; current_task_id = a.current_task_id
  }
;;

let agent_info_of_proto (p : P.AgentInfo.t) : agent_info =
  { name = p.name
  ; status = p.status
  ; capabilities = p.capabilities
  ; last_heartbeat_ms = p.last_heartbeat_ms
  ; session_bound_at_ms = p.session_bound_at_ms
  ; current_task_id = p.current_task_id
  }
;;

(** Convert our [task_info] to a protobuf TaskInfo and back. *)
let task_info_to_proto (t : task_info) : P.TaskInfo.t =
  { id = t.id
  ; title = t.title
  ; status = t.status
  ; assigned_to = t.assigned_to
  ; priority = t.priority
  }
;;

let task_info_of_proto (p : P.TaskInfo.t) : task_info =
  { id = p.id
  ; title = p.title
  ; status = p.status
  ; assigned_to = p.assigned_to
  ; priority = p.priority
  }
;;

(** {1 Heartbeat} *)

module HeartbeatPing = struct
  type t =
    { agent_name : string
    ; session_id : string
    ; timestamp_ms : int64
    ; current_task_id : string
    }

  let of_bytes_result bytes =
    match decode_result ~type_name:"HeartbeatPing" P.HeartbeatPing.from_proto bytes with
    | Ok p ->
      Ok
        ({ agent_name = p.agent_name
         ; session_id = p.session_id
         ; timestamp_ms = p.timestamp_ms
         ; current_task_id = p.current_task_id
         }
         : t)
    | Error _ as err -> err
  ;;

  let of_bytes bytes =
    match of_bytes_result bytes with
    | Ok ping -> ping
    | Error msg -> invalid_arg msg
  ;;

  let to_bytes (t : t) =
    encode
      P.HeartbeatPing.to_proto
      { agent_name = t.agent_name
      ; session_id = t.session_id
      ; timestamp_ms = t.timestamp_ms
      ; current_task_id = t.current_task_id
      }
  ;;
end

module HeartbeatAck = struct
  type t =
    { timestamp_ms : int64
    ; active_agent_count : int
    ; pending_task_count : int
    ; directives : Keeper_directive.t list
    }

  type directive_wire =
    [ `Pause of bool
    | `Wakeup of bool
    | `Claim_task_id of string
    | `not_set
    ]

  (* The wire carries one oneof arm per directive, so a value that names no
     arm cannot be built. This used to be "pause" | "wakeup" |
     "claim:<task_id>": a prefix split on ':' and matched by name, which is
     how "resume" sat in the proto comment for months while every client that
     sent it got a decode failure instead of the documented behaviour
     (#29396 A6). [`not_set] is the one shape protobuf still admits — a
     Directive message with no field set — and it is a decode error. *)
  let directive_of_wire : directive_wire -> _ = function
    | `Pause _ -> Ok Keeper_directive.Pause
    | `Wakeup _ -> Ok Keeper_directive.Wakeup
    | `Claim_task_id payload ->
      (match Keeper_id.Task_id.of_string payload with
       | Ok task_id -> Ok (Keeper_directive.Assign_task task_id)
       | Error error ->
         Error
           (Printf.sprintf
              "invalid HeartbeatAck task assignment %S: %s"
              payload
              error))
    | `not_set -> Error "HeartbeatAck directive has no kind set"
  ;;

  let directive_to_wire : _ -> directive_wire = function
    | Keeper_directive.Pause -> `Pause true
    | Keeper_directive.Wakeup -> `Wakeup true
    | Keeper_directive.Assign_task task_id ->
      `Claim_task_id (Keeper_id.Task_id.to_string task_id)
  ;;

  let decode_directives directives =
    let rec loop decoded = function
      | [] -> List.rev decoded
      | raw :: rest ->
        (match directive_of_wire raw with
         | Ok directive -> loop (directive :: decoded) rest
         | Error error -> invalid_arg error)
    in
    loop [] directives
  ;;

  let of_bytes bytes =
    let p = decode ~type_name:"HeartbeatAck" P.HeartbeatAck.from_proto bytes in
    { timestamp_ms = p.timestamp_ms
    ; active_agent_count = p.active_agent_count
    ; pending_task_count = p.pending_task_count
    ; directives = decode_directives p.directives
    }
  ;;

  let to_bytes (t : t) =
    encode
      P.HeartbeatAck.to_proto
      { timestamp_ms = t.timestamp_ms
      ; active_agent_count = t.active_agent_count
      ; pending_task_count = t.pending_task_count
      ; directives = List.map directive_to_wire t.directives
      }
  ;;
end

(** {1 Event Subscription} *)

module SubscribeRequest = struct
  type t =
    { agent_name : string
    ; session_id : string
    ; event_types : string list
    ; since_seq : int64
    }

  let of_bytes_result bytes =
    match decode_result ~type_name:"SubscribeRequest" P.SubscribeRequest.from_proto bytes with
    | Ok p ->
      Ok
        ({ agent_name = p.agent_name
         ; session_id = p.session_id
         ; event_types = p.event_types
         ; since_seq = p.since_seq
         }
         : t)
    | Error _ as err -> err
  ;;

  let of_bytes bytes =
    match of_bytes_result bytes with
    | Ok req -> req
    | Error msg -> invalid_arg msg
  ;;
end

module SubscribeRequest_serde = struct
  let to_bytes (t : SubscribeRequest.t) =
    encode
      P.SubscribeRequest.to_proto
      { agent_name = t.agent_name
      ; session_id = t.session_id
      ; event_types = t.event_types
      ; since_seq = t.since_seq
      }
  ;;
end

module Event = struct
  type t =
    { seq : int64
    ; event_type : string
    ; source_agent : string
    ; timestamp_ms : int64
    ; payload_json : string
    }

  let of_bytes bytes =
    let p = decode ~type_name:"Event" P.Event.from_proto bytes in
    { seq = p.seq
    ; event_type = p.event_type
    ; source_agent = p.source_agent
    ; timestamp_ms = p.timestamp_ms
    ; payload_json = p.payload_json
    }
  ;;

  let to_bytes (t : t) =
    encode
      P.Event.to_proto
      { seq = t.seq
      ; event_type = t.event_type
      ; source_agent = t.source_agent
      ; timestamp_ms = t.timestamp_ms
      ; payload_json = t.payload_json
      }
  ;;
end

(** {1 Tool Call} *)

module ToolCallRequest = struct
  type t =
    { agent_name : string
    ; session_id : string
    ; tool_name : string
    ; arguments_json : string
    }

  let of_bytes_result bytes =
    match decode_result ~type_name:"ToolCallRequest" P.ToolCallRequest.from_proto bytes with
    | Ok p ->
      Ok
        ({ agent_name = p.agent_name
         ; session_id = p.session_id
         ; tool_name = p.tool_name
         ; arguments_json = p.arguments_json
         }
         : t)
    | Error _ as err -> err
  ;;

  let of_bytes bytes =
    match of_bytes_result bytes with
    | Ok req -> req
    | Error msg -> invalid_arg msg
  ;;

  let to_bytes (t : t) =
    encode
      P.ToolCallRequest.to_proto
      { agent_name = t.agent_name
      ; session_id = t.session_id
      ; tool_name = t.tool_name
      ; arguments_json = t.arguments_json
      }
  ;;
end

module ToolCallResponse = struct
  type t =
    { success : bool
    ; result_json : string
    ; error_message : string
    ; error_code : int
    }

  let of_bytes bytes =
    let p = decode ~type_name:"ToolCallResponse" P.ToolCallResponse.from_proto bytes in
    { success = p.success
    ; result_json = p.result_json
    ; error_message = p.error_message
    ; error_code = p.error_code
    }
  ;;

  let to_bytes (t : t) =
    encode
      P.ToolCallResponse.to_proto
      { success = t.success
      ; result_json = t.result_json
      ; error_message = t.error_message
      ; error_code = t.error_code
      }
  ;;
end

(** {1 Broadcast} *)

module BroadcastRequest = struct
  type t =
    { agent_name : string
    ; message : string
    ; mentions : string list
    }

  let of_bytes_result bytes =
    match decode_result ~type_name:"BroadcastRequest" P.BroadcastRequest.from_proto bytes with
    | Ok p ->
      Ok ({ agent_name = p.agent_name; message = p.message; mentions = p.mentions } : t)
    | Error _ as err -> err
  ;;

  let of_bytes bytes =
    match of_bytes_result bytes with
    | Ok req -> req
    | Error msg -> invalid_arg msg
  ;;

  let to_bytes (t : t) =
    encode
      P.BroadcastRequest.to_proto
      { agent_name = t.agent_name; message = t.message; mentions = t.mentions }
  ;;
end

module BroadcastResponse = struct
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

  let delivery_status_to_wire = function
    | Delivery_passive -> "passive"
    | Delivery_accepted -> "accepted"
    | Delivery_already_accepted -> "already_accepted"
    | Delivery_pending -> "pending"
    | Delivery_deferred -> "deferred"
    | Delivery_rejected -> "rejected"
    | Delivery_not_persisted -> "not_persisted"
    | Delivery_outcome_unknown -> "outcome_unknown"
  ;;

  let delivery_status_of_wire = function
    | "passive" -> Delivery_passive
    | "accepted" -> Delivery_accepted
    | "already_accepted" -> Delivery_already_accepted
    | "pending" -> Delivery_pending
    | "deferred" -> Delivery_deferred
    | "rejected" -> Delivery_rejected
    | "not_persisted" -> Delivery_not_persisted
    | "outcome_unknown" -> Delivery_outcome_unknown
    | value -> invalid_arg (Printf.sprintf "unknown BroadcastResponse.delivery_status: %S" value)
  ;;

  let retry_disposition_to_wire = function
    | Retry_do_not_resend -> "do_not_resend"
    | Retry_allowed -> "retry_allowed"
    | Retry_outcome_unknown -> "outcome_unknown"
  ;;

  let retry_disposition_of_wire = function
    | "do_not_resend" -> Retry_do_not_resend
    | "retry_allowed" -> Retry_allowed
    | "outcome_unknown" -> Retry_outcome_unknown
    | value -> invalid_arg (Printf.sprintf "unknown BroadcastResponse.retry_disposition: %S" value)
  ;;

  let workspace_persistence_status_to_wire = function
    | Workspace_persisted -> "persisted"
    | Workspace_not_persisted -> "not_persisted"
    | Workspace_persistence_unknown -> "outcome_unknown"
  ;;

  let workspace_persistence_status_of_wire = function
    | "persisted" -> Workspace_persisted
    | "not_persisted" -> Workspace_not_persisted
    | "outcome_unknown" -> Workspace_persistence_unknown
    | value ->
      invalid_arg
        (Printf.sprintf
           "unknown BroadcastResponse.workspace_persistence_status: %S"
           value)
  ;;


  let of_bytes bytes =
    let p = decode ~type_name:"BroadcastResponse" P.BroadcastResponse.from_proto bytes in
    { success = p.success
    ; seq = p.seq
    ; request_id = p.request_id
    ; delivery_status = delivery_status_of_wire p.delivery_status
    ; delivery_reason = p.delivery_reason
    ; workspace_persistence_status =
        workspace_persistence_status_of_wire p.workspace_persistence_status
    ; retry_disposition = retry_disposition_of_wire p.retry_disposition
    }
  ;;

  let to_bytes (t : t) =
    encode
      P.BroadcastResponse.to_proto
      { success = t.success
      ; seq = t.seq
      ; request_id = t.request_id
      ; delivery_status = delivery_status_to_wire t.delivery_status
      ; delivery_reason = t.delivery_reason
      ; workspace_persistence_status =
          workspace_persistence_status_to_wire t.workspace_persistence_status
      ; retry_disposition = retry_disposition_to_wire t.retry_disposition
      }
  ;;
end

(** {1 Status} *)

module StatusResponse = struct
  type t =
    { agents : agent_info list
    ; tasks : task_info list
    ; message_count : int
    ; workspace_path : string
    }

  let of_bytes bytes =
    let p = decode ~type_name:"StatusResponse" P.StatusResponse.from_proto bytes in
    { agents = List.map agent_info_of_proto p.agents
    ; tasks = List.map task_info_of_proto p.tasks
    ; message_count = p.message_count
    ; workspace_path = p.workspace_path
    }
  ;;

  let to_bytes (t : t) =
    encode
      P.StatusResponse.to_proto
      { agents = List.map agent_info_to_proto t.agents
      ; tasks = List.map task_info_to_proto t.tasks
      ; message_count = t.message_count
      ; workspace_path = t.workspace_path
      }
  ;;
end

