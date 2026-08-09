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
