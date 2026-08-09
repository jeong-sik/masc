(** Exact JSON-RPC/MCP bridge shared by official subscription clients.

    Client adapters own their transport and tool representation. This module's
    parsed-message entrypoint owns protocol validation and dispatch:
    initialize, tools/list, tools/call, and notification no-response
    semantics. Each client adapter owns its raw transport parsing. *)

type error =
  { stage : string
  ; detail : string
  }

type tool_result =
  { success : bool
  ; content : string
  }

type dispatch =
  { response : Yojson.Safe.t option
  ; tool_called : bool
  }

type tool_call = private
  { id : Yojson.Safe.t
  ; name : string
  ; call_id : string
  ; arguments : Yojson.Safe.t
  }

type prepared =
  | Prepared_response of dispatch
  | Prepared_tools_list of { id : Yojson.Safe.t }
  | Prepared_tool_call of tool_call

type phase =
  | Awaiting_initialize
  | Awaiting_initialized
  | Ready

type session_snapshot =
  { phase : phase
  ; negotiated_protocol_version : string option
  }

type session

val create_session : unit -> session
(** Fresh closed lifecycle: initialize, initialized notification, then Ready. *)

val snapshot_session : session -> session_snapshot
(** One immutable observation of lifecycle phase and negotiated protocol. *)

val prepare_message :
  session:session ->
  server_name:string ->
  Yojson.Safe.t ->
  (prepared, error) result
(** Validate one message and commit only its protocol-state transition. Tool
    inventory and tool effects are returned as typed work for the transport
    owner to execute outside any protocol-state critical section. *)

val complete_tools_list : id:Yojson.Safe.t -> Yojson.Safe.t list -> dispatch
val complete_tool_call : tool_call -> tool_result option -> dispatch

val handle_message :
  session:session ->
  server_name:string ->
  tool_specs:(unit -> Yojson.Safe.t list) ->
  call_tool:
    (name:string ->
     call_id:string ->
     arguments:Yojson.Safe.t ->
     tool_result option) ->
  Yojson.Safe.t ->
  (dispatch, error) result
