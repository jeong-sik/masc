type token_source =
  | Internal_keeper_token
  | Internal_keeper_env
  | Mcp_bearer_env
  | Provider_api_key_env of { var_name : string }

type token = { raw : string; source : token_source }

type auth_error =
  | Token_hash_missing of { path : string }
  | Token_hash_mismatch of {
      keeper_id : string;
      presented_source : token_source;
    }
  | Credential_file_missing of { path : string }
  | Api_key_env_unset of { var_name : string }
  | Bound_actor_provider_mismatch of {
      provider_kind : Llm_provider.Provider_config.provider_kind;
    }

let token_source_label = function
  | Internal_keeper_token -> "internal_keeper_token"
  | Internal_keeper_env -> "internal_keeper_env"
  | Mcp_bearer_env -> "mcp_bearer_env"
  | Provider_api_key_env { var_name } ->
      "provider_api_key_env:" ^ var_name

let pp_auth_error fmt = function
  | Token_hash_missing { path } ->
      Format.fprintf fmt "token_hash_missing(path=%s)" path
  | Token_hash_mismatch { keeper_id; presented_source } ->
      Format.fprintf fmt "token_hash_mismatch(keeper=%s,via=%s)"
        keeper_id
        (token_source_label presented_source)
  | Credential_file_missing { path } ->
      Format.fprintf fmt "credential_file_missing(path=%s)" path
  | Api_key_env_unset { var_name } ->
      Format.fprintf fmt "api_key_env_unset(var=%s)" var_name
  | Bound_actor_provider_mismatch { provider_kind } ->
      Format.fprintf fmt "bound_actor_provider_mismatch(kind=%s)"
        (Llm_provider.Provider_kind.to_string provider_kind)

let show_auth_error e =
  let buf = Buffer.create 64 in
  let fmt = Format.formatter_of_buffer buf in
  pp_auth_error fmt e;
  Format.pp_print_flush fmt ();
  Buffer.contents buf

let first_nonempty_env keys =
  List.find_map
    (fun key ->
      match Sys.getenv_opt key with
      | Some v when String.trim v <> "" -> Some (String.trim v, key)
      | _ -> None)
    keys

let internal_keeper_token_hash_file ~base_path =
  Filename.concat base_path ".masc/auth/internal_keeper.token.hash"

let resolve ~base_path ~keeper_id ~provider_kind
    ~policy_requires_runtime_mcp =
  let module PK = Llm_provider.Provider_config in
  if policy_requires_runtime_mcp then
    match keeper_id with
    | None -> (
        match first_nonempty_env [ "MASC_MCP_TOKEN" ] with
        | Some (raw, _) -> Ok { raw; source = Mcp_bearer_env }
        | None -> Error (Api_key_env_unset { var_name = "MASC_MCP_TOKEN" }))
    | Some _ ->
        let hash_path = internal_keeper_token_hash_file ~base_path in
        if Sys.file_exists hash_path then
          match
            first_nonempty_env
              [ "MASC_INTERNAL_MCP_TOKEN"; "MASC_MCP_TOKEN" ]
          with
          | Some (raw, "MASC_INTERNAL_MCP_TOKEN") ->
              Ok { raw; source = Internal_keeper_env }
          | Some (raw, _) -> Ok { raw; source = Mcp_bearer_env }
          | None ->
              Error
                (Api_key_env_unset { var_name = "MASC_INTERNAL_MCP_TOKEN" })
        else Error (Token_hash_missing { path = hash_path })
  else
    match Llm_provider.Provider_kind.default_api_key_env provider_kind with
    | None -> (
        match provider_kind with
        | PK.Codex_cli ->
            Error (Bound_actor_provider_mismatch { provider_kind })
        | _ -> (
            match first_nonempty_env [ "MASC_MCP_TOKEN" ] with
            | Some (raw, _) -> Ok { raw; source = Mcp_bearer_env }
            | None ->
                Error (Api_key_env_unset { var_name = "MASC_MCP_TOKEN" })))
    | Some var_name -> (
        match first_nonempty_env [ var_name ] with
        | Some (raw, _) ->
            Ok { raw; source = Provider_api_key_env { var_name } }
        | None -> Error (Api_key_env_unset { var_name }))

let emit_resolution_trace ~cascade ~keeper_id ~provider_label ~outcome =
  let keeper_label = Option.value keeper_id ~default:"-" in
  match outcome with
  | Ok { source; _ } ->
      Log.Auth.info
        ?keeper_name:keeper_id
        "auth_resolve: cascade=%s provider=%s keeper=%s outcome=ok source=%s"
        cascade provider_label keeper_label
        (token_source_label source)
  | Error err ->
      Log.Auth.error
        ?keeper_name:keeper_id
        "auth_resolve: cascade=%s provider=%s keeper=%s outcome=error reason=%s"
        cascade provider_label keeper_label
        (show_auth_error err)
