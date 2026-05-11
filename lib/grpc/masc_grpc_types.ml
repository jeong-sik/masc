(** MASC gRPC Coordination Masc_domain.

    Wire format: protobuf binary over gRPC framing.
    Types are generated from proto/masc_coordination.proto via ocaml-protoc-plugin.

    Each message type provides [to_bytes] and [of_bytes] for the
    grpc-direct handler interface (string -> string).

    The generated protobuf modules live under [Masc_proto.Masc_coordination.Masc.Coordination.V1]. *)

module P = Masc_proto.Masc_coordination.Masc.Coordination.V1

(** {1 Protobuf Serialization Helpers} *)

(** Serialize a protobuf message to a binary string. *)
let encode to_proto msg = Ocaml_protoc_plugin.Writer.contents (to_proto msg)

(** Deserialize a protobuf message from a binary string. *)
let decode_result from_proto bytes =
  let reader = Ocaml_protoc_plugin.Reader.create bytes in
  match from_proto reader with
  | Ok v -> Ok v
  | Error e ->
    Error
      (Printf.sprintf
         "protobuf decode error: %s"
         (Ocaml_protoc_plugin.Result.show_error e))
;;

(** Deserialize a protobuf message from a binary string.
    Raises [Invalid_argument] on parse error. *)
let decode from_proto bytes =
  match decode_result from_proto bytes with
  | Ok v -> v
  | Error msg -> invalid_arg msg
;;

(** {1 Shared Types} *)

type agent_info =
  { name : string
  ; status : string
  ; capabilities : string list
  ; last_heartbeat_ms : int64
  ; joined_at_ms : int64
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
  ; joined_at_ms = a.joined_at_ms
  ; current_task_id = a.current_task_id
  }
;;

let agent_info_of_proto (p : P.AgentInfo.t) : agent_info =
  { name = p.name
  ; status = p.status
  ; capabilities = p.capabilities
  ; last_heartbeat_ms = p.last_heartbeat_ms
  ; joined_at_ms = p.joined_at_ms
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

(** {1 Agent Lifecycle} *)

module JoinRequest = struct
  type t =
    { agent_name : string
    ; capabilities : string list
    ; metadata : (string * string) list
    }

  let of_bytes_result bytes =
    match decode_result P.JoinRequest.from_proto bytes with
    | Ok p ->
      Ok
        ({ agent_name = p.agent_name
         ; capabilities = p.capabilities
         ; metadata = p.metadata
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
      P.JoinRequest.to_proto
      { agent_name = t.agent_name; capabilities = t.capabilities; metadata = t.metadata }
  ;;
end

module JoinResponse = struct
  type t =
    { success : bool
    ; message : string
    ; session_id : string
    ; active_agents : agent_info list
    }

  let of_bytes bytes =
    let p = decode P.JoinResponse.from_proto bytes in
    { success = p.success
    ; message = p.message
    ; session_id = p.session_id
    ; active_agents = List.map agent_info_of_proto p.active_agents
    }
  ;;

  let to_bytes (t : t) =
    encode
      P.JoinResponse.to_proto
      { success = t.success
      ; message = t.message
      ; session_id = t.session_id
      ; active_agents = List.map agent_info_to_proto t.active_agents
      }
  ;;
end

module LeaveRequest = struct
  type t =
    { agent_name : string
    ; session_id : string
    }

  let of_bytes_result bytes =
    match decode_result P.LeaveRequest.from_proto bytes with
    | Ok p -> Ok ({ agent_name = p.agent_name; session_id = p.session_id } : t)
    | Error _ as err -> err
  ;;

  let of_bytes bytes =
    match of_bytes_result bytes with
    | Ok req -> req
    | Error msg -> invalid_arg msg
  ;;

  let to_bytes (t : t) =
    encode
      P.LeaveRequest.to_proto
      { agent_name = t.agent_name; session_id = t.session_id }
  ;;
end

module LeaveResponse = struct
  type t =
    { success : bool
    ; message : string
    }

  let of_bytes bytes =
    let p = decode P.LeaveResponse.from_proto bytes in
    { success = p.success; message = p.message }
  ;;

  let to_bytes (t : t) =
    encode P.LeaveResponse.to_proto { success = t.success; message = t.message }
  ;;
end

(** {1 Heartbeat} *)

module HeartbeatPing = struct
  type t =
    { agent_name : string
    ; session_id : string
    ; timestamp_ms : int64
    ; current_task_id : string
    }

  let of_bytes_result bytes =
    match decode_result P.HeartbeatPing.from_proto bytes with
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
    ; directives : string list
    }

  let of_bytes bytes =
    let p = decode P.HeartbeatAck.from_proto bytes in
    { timestamp_ms = p.timestamp_ms
    ; active_agent_count = p.active_agent_count
    ; pending_task_count = p.pending_task_count
    ; directives = p.directives
    }
  ;;

  let to_bytes (t : t) =
    encode
      P.HeartbeatAck.to_proto
      { timestamp_ms = t.timestamp_ms
      ; active_agent_count = t.active_agent_count
      ; pending_task_count = t.pending_task_count
      ; directives = t.directives
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
    match decode_result P.SubscribeRequest.from_proto bytes with
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
    let p = decode P.Event.from_proto bytes in
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
    match decode_result P.ToolCallRequest.from_proto bytes with
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
    let p = decode P.ToolCallResponse.from_proto bytes in
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
    match decode_result P.BroadcastRequest.from_proto bytes with
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
  type t =
    { success : bool
    ; seq : int64
    }

  let of_bytes bytes =
    let p = decode P.BroadcastResponse.from_proto bytes in
    { success = p.success; seq = p.seq }
  ;;

  let to_bytes (t : t) =
    encode P.BroadcastResponse.to_proto { success = t.success; seq = t.seq }
  ;;
end

(** {1 Status} *)

module StatusResponse = struct
  type t =
    { agents : agent_info list
    ; tasks : task_info list
    ; message_count : int
    ; room_path : string
    }

  let of_bytes bytes =
    let p = decode P.StatusResponse.from_proto bytes in
    { agents = List.map agent_info_of_proto p.agents
    ; tasks = List.map task_info_of_proto p.tasks
    ; message_count = p.message_count
    ; room_path = p.room_path
    }
  ;;

  let to_bytes (t : t) =
    encode
      P.StatusResponse.to_proto
      { agents = List.map agent_info_to_proto t.agents
      ; tasks = List.map task_info_to_proto t.tasks
      ; message_count = t.message_count
      ; room_path = t.room_path
      }
  ;;
end

(** {1 LSP Proxy} *)

module LspRequest = struct
  type t =
    { language_id : string
    ; jsonrpc_request_json : string
    ; workspace_root : string option
    }

  let of_bytes_result bytes =
    match decode_result P.LspRequest.from_proto bytes with
    | Ok p ->
      Ok
        ({ language_id = p.language_id
         ; jsonrpc_request_json = p.jsonrpc_request_json
         ; workspace_root =
             (match p.workspace_root with
              | "" -> None
              | s -> Some s)
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
      P.LspRequest.to_proto
      { language_id = t.language_id
      ; jsonrpc_request_json = t.jsonrpc_request_json
      ; workspace_root = Option.value ~default:"" t.workspace_root
      }
  ;;
end

module LspResponse = struct
  type t =
    { jsonrpc_response_json : string
    ; error_message : string
    }

  let of_bytes bytes =
    let p = decode P.LspResponse.from_proto bytes in
    { jsonrpc_response_json = p.jsonrpc_response_json; error_message = p.error_message }
  ;;

  let to_bytes (t : t) =
    encode
      P.LspResponse.to_proto
      { jsonrpc_response_json = t.jsonrpc_response_json; error_message = t.error_message }
  ;;
end
