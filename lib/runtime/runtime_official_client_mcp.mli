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

val handle_message :
  server_name:string ->
  tool_specs:(unit -> Yojson.Safe.t list) ->
  call_tool:
    (name:string ->
     call_id:string ->
     arguments:Yojson.Safe.t ->
     tool_result option) ->
  Yojson.Safe.t ->
  (dispatch, error) result
