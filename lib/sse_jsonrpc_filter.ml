(** JSON-RPC payload filter for SSE coordinator sessions. *)

(** JSON-RPC payloads are the only durable events safe for MCP coordinator
    clients. Dashboard/activity JSON may share the SSE hub, but it is not
    JSON-RPC and causes strict MCP clients to raise parse errors. *)
let jsonrpc_message_for_coordinator = function
  | `Assoc fields ->
    (match List.assoc_opt "jsonrpc" fields with
     | Some (`String "2.0") ->
       List.mem_assoc "method" fields
       || List.mem_assoc "id" fields
       || List.mem_assoc "result" fields
       || List.mem_assoc "error" fields
     | _ -> false)
  | _ -> false

let event_data_payload event =
  let prefix = "data: " in
  let prefix_len = String.length prefix in
  let data_lines =
    event
    |> String.split_on_char '\n'
    |> List.filter_map (fun line ->
      if String.starts_with ~prefix line
      then Some (String.sub line prefix_len (String.length line - prefix_len))
      else None)
  in
  match data_lines with
  | [] -> None
  | lines -> Some (String.concat "\n" lines)

let event_string_jsonrpc_message_for_coordinator event =
  match event_data_payload event with
  | None -> false
  | Some data ->
    (try jsonrpc_message_for_coordinator (Yojson.Safe.from_string data) with
     | Yojson.Json_error _ -> false)
