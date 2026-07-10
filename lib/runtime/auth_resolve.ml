type token_source =
  | Mcp_bearer_env
  | Per_keeper_token_file
  | Provider_api_key_env of { var_name : string }

type token = {
  raw : string;
  source : token_source;
  verified_agent_name : string option;
}

type verification_failure =
  | Invalid_token
  | Token_expired of { agent_name : string }
  | Actor_mismatch
  | Unauthorized
  | Forbidden
  | Credential_store_failure
  | Unexpected_auth_failure

type auth_error =
  | Raw_token_unavailable of { agent_name : string }
  | Credential_verification_failed of {
      agent_name : string;
      presented_source : token_source;
      failure : verification_failure;
    }
  | Credential_owner_mismatch of {
      expected_agent_name : string;
      actual_agent_name : string;
      presented_source : token_source;
    }
  | Unbound_token_verification_failed of {
      presented_source : token_source;
      failure : verification_failure;
    }
  | Api_key_env_unset of { var_name : string }
  | Bound_actor_provider_mismatch of {
      provider_kind : Llm_provider.Provider_config.provider_kind;
    }

let token_source_label = function
  | Mcp_bearer_env -> "mcp_bearer_env"
  | Per_keeper_token_file -> "per_keeper_token_file"
  | Provider_api_key_env { var_name } ->
      "provider_api_key_env:" ^ var_name

let verification_failure_label = function
  | Invalid_token -> "invalid_token"
  | Token_expired _ -> "token_expired"
  | Actor_mismatch -> "actor_mismatch"
  | Unauthorized -> "unauthorized"
  | Forbidden -> "forbidden"
  | Credential_store_failure -> "credential_store_failure"
  | Unexpected_auth_failure -> "unexpected_auth_failure"

let verification_failure_of_masc_error = function
  | Masc_domain.Auth (Masc_domain.Auth_error.InvalidToken _) -> Invalid_token
  | Masc_domain.Auth (Masc_domain.Auth_error.TokenExpired agent_name) ->
      Token_expired { agent_name }
  | Masc_domain.Auth
      (Masc_domain.Auth_error.Unauthorized
        { reason = Masc_domain.Auth_error.Actor_mismatch; _ }) ->
      Actor_mismatch
  | Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized _) -> Unauthorized
  | Masc_domain.Auth (Masc_domain.Auth_error.Forbidden _) -> Forbidden
  | Masc_domain.System _ -> Credential_store_failure
  | Masc_domain.Task _
  | Masc_domain.Agent _
  | Masc_domain.RateLimitExceeded _
  | Masc_domain.CacheError _ ->
      Unexpected_auth_failure

let pp_auth_error fmt = function
  | Raw_token_unavailable { agent_name } ->
      Format.fprintf fmt "raw_token_unavailable(agent=%s)" agent_name
  | Credential_verification_failed
      { agent_name; presented_source; failure } ->
      Format.fprintf fmt "credential_verification_failed(agent=%s,via=%s,reason=%s)"
        agent_name
        (token_source_label presented_source)
        (verification_failure_label failure)
  | Credential_owner_mismatch
      { expected_agent_name; actual_agent_name; presented_source } ->
      Format.fprintf fmt
        "credential_owner_mismatch(expected=%s,actual=%s,via=%s)"
        expected_agent_name actual_agent_name
        (token_source_label presented_source)
  | Unbound_token_verification_failed { presented_source; failure } ->
      Format.fprintf fmt "unbound_token_verification_failed(via=%s,reason=%s)"
        (token_source_label presented_source)
        (verification_failure_label failure)
  | Api_key_env_unset { var_name } ->
      Format.fprintf fmt "api_key_env_unset(var=%s)" var_name
  | Bound_actor_provider_mismatch { provider_kind } ->
      Format.fprintf fmt "bound_actor_provider_mismatch(kind=%s)"
        (Runtime_provider_credentials.provider_kind_label provider_kind)

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
      | Some v ->
          let trimmed = String.trim v in
          if trimmed <> "" then Some (trimmed, key) else None
      | None -> None)
    keys

let resolve_runtime_mcp ~base_path ~agent_name =
  match agent_name with
  | Some agent_name -> (
      let presented_source = Per_keeper_token_file in
      match Auth.load_raw_token base_path ~agent_name with
      | None -> Error (Raw_token_unavailable { agent_name })
      | Some raw -> (
          match Auth.verify_token base_path ~agent_name ~token:raw with
          | Error error ->
              Error
                (Credential_verification_failed
                   {
                     agent_name;
                     presented_source;
                     failure = verification_failure_of_masc_error error;
                   })
          | Ok credential
            when String.equal credential.Masc_domain.agent_name agent_name ->
              Ok
                {
                  raw;
                  source = presented_source;
                  verified_agent_name = Some credential.agent_name;
                }
          | Ok credential ->
              Error
                (Credential_owner_mismatch
                   {
                     expected_agent_name = agent_name;
                     actual_agent_name = credential.agent_name;
                     presented_source;
                   })))
  | None -> (
      let presented_source = Mcp_bearer_env in
      match first_nonempty_env [ "MASC_TOKEN" ] with
      | None -> Error (Api_key_env_unset { var_name = "MASC_TOKEN" })
      | Some (raw, _) -> (
          match Auth.resolve_agent_from_token base_path ~token:raw with
          | Ok verified_agent_name ->
              Ok
                {
                  raw;
                  source = presented_source;
                  verified_agent_name = Some verified_agent_name;
                }
          | Error error ->
              Error
                (Unbound_token_verification_failed
                   {
                     presented_source;
                     failure = verification_failure_of_masc_error error;
                   })))

let resolve ~base_path ~agent_name ~provider_kind
    ~policy_requires_runtime_mcp =
  if policy_requires_runtime_mcp then
    resolve_runtime_mcp ~base_path ~agent_name
  else
    match Runtime_provider_credentials.api_key_env_var_for_kind provider_kind with
    | None ->
        (* Providers requiring per-keeper bridging cannot accept the shared
           [MASC_TOKEN] fallback: their bound-actor runtime MCP tools need
           a per-keeper raw bearer. Dispatch by local tool-delivery policy,
           not by provider name. RFC-0058 §2.4: capability, not match. *)
        if
          Provider_tool_support
          .provider_kind_requires_per_keeper_bridging_for_bound_actor_tools
            provider_kind
        then Error (Bound_actor_provider_mismatch { provider_kind })
        else resolve_runtime_mcp ~base_path ~agent_name:None
    | Some var_name -> (
        match first_nonempty_env [ var_name ] with
        | Some (raw, _) ->
            Ok
              {
                raw;
                source = Provider_api_key_env { var_name };
                verified_agent_name = None;
              }
        | None -> Error (Api_key_env_unset { var_name }))

let emit_resolution_trace ~runtime ~keeper_id ~provider_label ~outcome =
  let keeper_label = Option.value keeper_id ~default:"-" in
  match outcome with
  | Ok { source; verified_agent_name; _ } ->
      Log.Auth.routine
        ?keeper_name:keeper_id
        "auth_resolve: runtime=%s provider=%s keeper=%s outcome=ok source=%s verified_owner=%s"
        runtime provider_label keeper_label
        (token_source_label source)
        (* DET-OK: absent verified identity is rendered only in diagnostics. *)
        (Option.value verified_agent_name ~default:"-")
  | Error err ->
      Log.Auth.error
        ?keeper_name:keeper_id
        "auth_resolve: runtime=%s provider=%s keeper=%s outcome=error reason=%s"
        runtime provider_label keeper_label
        (show_auth_error err)
