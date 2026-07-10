(** Runtime-MCP policy header helpers, extracted from
    [runtime_transport.ml]. Two pure transforms over
    [Llm_provider.Llm_transport.runtime_mcp_policy]:

    - [runtime_mcp_policy_with_masc_agent_name] injects non-secret
      x-masc-agent-name / x-masc-keeper-name identity headers into the
      "masc" HTTP server entry.
    - [runtime_mcp_policy_without_http_headers] strips all headers from
      every HTTP server. *)

let upsert_http_header = Runtime_transport_authorization.upsert_http_header
let keeper_name_of_agent_name = Runtime_transport_authorization.keeper_name_of_agent_name

;;

let runtime_mcp_policy_with_masc_agent_name
      ~(agent_name : string)
      (policy : Llm_provider.Llm_transport.runtime_mcp_policy)
  =
  let agent_name = String.trim agent_name in
  if String.equal agent_name ""
  then policy
  else (
    let servers =
      List.map
        (function
          | Llm_provider.Llm_transport.Http_server ({ name; headers; _ } as server)
            when String.equal name "masc" ->
            let headers =
              upsert_http_header ~key:"x-masc-agent-name" ~value:agent_name headers
            in
            let headers =
              match keeper_name_of_agent_name agent_name with
              | Some keeper_name ->
                upsert_http_header ~key:"x-masc-keeper-name" ~value:keeper_name headers
              | None -> headers
            in
            Llm_provider.Llm_transport.Http_server { server with headers }
          | server -> server)
        policy.servers
    in
    { policy with servers })
;;

let runtime_mcp_policy_without_http_headers
      (policy : Llm_provider.Llm_transport.runtime_mcp_policy)
  =
  let servers =
    List.map
      (function
        | Llm_provider.Llm_transport.Http_server server ->
          Llm_provider.Llm_transport.Http_server { server with headers = [] }
        | server -> server)
      policy.servers
  in
  { policy with servers }
;;
