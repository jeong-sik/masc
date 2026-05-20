(* CLI MCP config JSON serializer.

   Builds the `{ "mcpServers": { name: { ... } } }` JSON document that
   CLI providers (codex, claude_code, gemini variants) expect as
   --mcp-config argv. Filters servers by the runtime mcp policy's
   allowed_server_names whitelist (empty = allow all).

   Extracted from [Cascade_transport] (godfile decomp). Pure mapping
   over [Llm_provider.Llm_transport] values. *)

let json_of_string_pairs pairs = `Assoc (List.map (fun (k, v) -> k, `String v) pairs)

let json_of_cli_mcp_server = function
  | Llm_provider.Llm_transport.Stdio_server { command; args; env; _ } ->
    `Assoc
      [ "command", `String command
      ; "args", `List (List.map (fun arg -> `String arg) args)
      ; "env", json_of_string_pairs env
      ]
  | Llm_provider.Llm_transport.Http_server { url; headers; _ } ->
    `Assoc [ "url", `String url; "headers", json_of_string_pairs headers ]
;;

let cli_mcp_config_json_of_policy
      (policy : Llm_provider.Llm_transport.runtime_mcp_policy)
  : string option
  =
  let allowed_server_name name =
    match policy.allowed_server_names with
    | [] -> true
    | names -> List.mem name names
  in
  let servers =
    List.filter
      (fun server ->
         allowed_server_name (Llm_provider.Llm_transport.runtime_mcp_server_name server))
      policy.servers
  in
  match servers with
  | [] -> None
  | servers ->
    let config_json =
      `Assoc
        [ ( "mcpServers"
          , `Assoc
              (List.map
                 (fun server ->
                    ( Llm_provider.Llm_transport.runtime_mcp_server_name server
                    , json_of_cli_mcp_server server ))
                 servers) )
        ]
    in
    Some (Yojson.Safe.to_string config_json)
;;
