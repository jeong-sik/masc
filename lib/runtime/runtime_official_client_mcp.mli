(** Exact JSON-RPC/MCP bridge shared by official subscription clients.

    Client adapters own their transport and tool representation. This module's
    raw-text entrypoint owns JSON parsing and the protocol state: initialize,
    tools/list, tools/call, notification no-response semantics, and typed
    protocol failures. *)

type error_kind =
  | Json_parse
  | Protocol

type error =
  { kind : error_kind
  ; stage : string
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

type message

val decode_message : string -> (message, error) result
val message_method : message -> string
val message_request_id : message -> Yojson.Safe.t option

val dispatch_message :
  server_name:string ->
  tool_specs:(unit -> Yojson.Safe.t list) ->
  call_tool:
    (name:string ->
     call_id:string ->
     arguments:Yojson.Safe.t ->
     tool_result option) ->
  message ->
  (dispatch, error) result

val handle_message :
  server_name:string ->
  tool_specs:(unit -> Yojson.Safe.t list) ->
  call_tool:
    (name:string ->
     call_id:string ->
     arguments:Yojson.Safe.t ->
     tool_result option) ->
  string ->
  (dispatch, error) result
