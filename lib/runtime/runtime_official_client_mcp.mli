(** Exact JSON-RPC/MCP bridge shared by official subscription clients.

    Client adapters own their transport, raw JSON parsing, and tool
    representation. This module owns the typed protocol state: initialize,
    tools/list, tools/call, notification no-response semantics, and typed
    protocol failures. *)

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
