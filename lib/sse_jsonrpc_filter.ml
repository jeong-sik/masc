(** JSON-RPC payload filter for SSE agent_stream sessions. *)

(** JSON-RPC payloads are the only durable events safe for MCP agent_stream
    clients. Dashboard/activity JSON may share the SSE hub, but it is not
    JSON-RPC and causes strict MCP clients to raise parse errors. *)
let jsonrpc_message_for_agent_stream = function
  | `Assoc fields ->
    (match List.assoc_opt "jsonrpc" fields with
     | Some (`String "2.0") ->
       List.mem_assoc "method" fields
       || List.mem_assoc "id" fields
       || List.mem_assoc "result" fields
       || List.mem_assoc "error" fields
     | _ -> false)
  | _ -> false
