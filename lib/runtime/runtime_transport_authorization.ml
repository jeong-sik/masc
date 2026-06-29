(** Authorization header helpers for runtime runtime MCP transport,
    extracted from runtime_transport.ml.

    Pure functions over runtime-MCP policy + per-keeper auth headers;
    no protocol/transport state owned here. *)

let upsert_http_header ~key ~value headers =
  let key_lc = String.lowercase_ascii key in
  let retained =
    List.filter
      (fun (existing_key, _) ->
         not (String.equal (String.lowercase_ascii existing_key) key_lc))
      headers
  in
  (key, value) :: retained
;;

let keeper_name_of_agent_name agent_name =
  let prefix = "keeper-" in
  let suffix = "-agent" in
  let value = String.trim agent_name in
  let vlen = String.length value in
  let plen = String.length prefix in
  let slen = String.length suffix in
  if
    vlen > plen + slen
    && String.sub value 0 plen = prefix
    && String.sub value (vlen - slen) slen = suffix
  then Some (String.sub value plen (vlen - plen - slen))
  else None
;;

let is_authorization_header (key, value) =
  String.equal (String.lowercase_ascii (String.trim key)) "authorization"
  && String.starts_with ~prefix:"Bearer " (String.trim value)
;;

let authorization_header_from_policy
      (policy : Llm_provider.Llm_transport.runtime_mcp_policy)
  =
  List.find_map
    (function
      | Llm_provider.Llm_transport.Http_server { name = "masc"; headers; _ } ->
        List.find_opt is_authorization_header headers
      (* Only the [Http_server] entry whose [name = "masc"] carries the
         per-request Authorization header. Other named [Http_server]s and
         [Stdio_server]s contribute no auth header on this lane. New
         transport variants must re-decide explicitly. *)
      | Llm_provider.Llm_transport.Http_server _
      | Llm_provider.Llm_transport.Stdio_server _ -> None)
    policy.servers
;;

let per_keeper_authorization_header ~base_path ~agent_name =
  match keeper_name_of_agent_name agent_name with
  | None -> None
  | Some _ ->
    Auth.load_raw_token base_path ~agent_name
    |> Option.map (fun raw -> "Authorization", "Bearer " ^ raw)
;;

let runtime_mcp_policy_uses_bound_actor_tools
      (policy : Llm_provider.Llm_transport.runtime_mcp_policy)
  =
  List.exists Tool_catalog.requires_actor_binding policy.allowed_tool_names
;;

let add_masc_authorization_header
      authorization_header
      (policy : Llm_provider.Llm_transport.runtime_mcp_policy)
  =
  let servers =
    List.map
      (function
        | Llm_provider.Llm_transport.Http_server ({ name = "masc"; headers; _ } as server)
          ->
          Llm_provider.Llm_transport.Http_server
            { server with
              headers =
                upsert_http_header
                  ~key:(fst authorization_header)
                  ~value:(snd authorization_header)
                  headers
            }
        | server -> server)
      policy.servers
  in
  { policy with servers }
;;
