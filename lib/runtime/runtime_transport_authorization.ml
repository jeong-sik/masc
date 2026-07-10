(** Authorization header helpers for runtime MCP transport,
    extracted from runtime_transport.ml.

    Header transforms are pure. Per-agent header resolution delegates to the
    credential-verifying [Auth_resolve] SSOT and emits secret-free traces; no
    protocol/transport state is owned here. *)

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

let per_keeper_authorization_header ~base_path ~agent_name =
  let keeper_id = keeper_name_of_agent_name agent_name in
  let outcome =
    Auth_resolve.resolve_runtime_mcp ~base_path ~agent_name:(Some agent_name)
  in
  Auth_resolve.emit_resolution_trace ~runtime:"runtime_mcp_auth_bridge"
    ~keeper_id ~provider_label:"masc" ~outcome;
  Result.map
    (fun ({ Auth_resolve.raw; _ } : Auth_resolve.token) ->
      "Authorization", "Bearer " ^ raw)
    outcome
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
