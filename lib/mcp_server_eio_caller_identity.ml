type owner_keeper_identity = string * string option

type t = {
  agent_name : string;
  token : string option;
  has_explicit_agent_name : bool;
  verified_internal_keeper_runtime : bool;
  internal_keeper_runtime_tool : bool;
  owner_keeper_identity : owner_keeper_identity option;
  mode_gate_error : string option;
}

let silent_auth_token_error_kind err =
  Auth_error_kind.to_string (Auth_error_kind.classify err)

let should_read_legacy_persisted_agent_name ~has_explicit_agent_name ~agent_name =
  (not has_explicit_agent_name) && Agent_name_kind.is_ephemeral agent_name

let caller_agent_name_from_arguments arguments =
  let nonempty_nonunknown key =
    match Safe_ops.json_string_opt key arguments with
    | Some value ->
        let value = String.trim value in
        if value <> "" && value <> "unknown" then
          Some value
        else
          None
    | None -> None
  in
  match nonempty_nonunknown "_agent_name" with
  | Some _ as value -> value
  | None -> nonempty_nonunknown "agent_name"

let direct_call_block_message name =
  if Tool_catalog.is_on_surface Tool_catalog.Keeper_internal name then (
    let replacement_hint =
      match (Tool_catalog.metadata name).Tool_catalog.replacement with
      | Some replacement -> Printf.sprintf " Try `%s` instead." replacement
      | None -> ""
    in
    Printf.sprintf
      "Tool '%s' is keeper-internal and not callable from external MCP clients.%s"
      name replacement_hint)
  else
    Printf.sprintf
      "Tool '%s' is hidden from the default tool surface and not callable directly."
      name

let resolve_owner_keeper_identity config owner_name =
  let candidates =
    [
      Keeper_types.canonical_keeper_name owner_name;
      Keeper_types.canonical_keeper_name_from_agent_name owner_name;
    ]
    |> List.filter_map (function
         | Some value ->
             let trimmed = String.trim value in
             if trimmed <> "" then
               Some trimmed
             else
               None
         | None -> None)
    |> List.sort_uniq String.compare
  in
  let rec loop = function
    | [] -> None
    | candidate :: rest -> (
        match Keeper_types.read_meta_resolved config candidate with
        | Ok (Some (resolved_name, meta)) ->
            Some
              (resolved_name, Option.map Keeper_id.Uid.to_string meta.Keeper_types.keeper_id)
        | Ok None -> loop rest
        | Error _ -> loop rest)
  in
  loop candidates

let resolve_initial_agent_name ~identity ~cached_resolved_agent ~mcp_session_id
    ~explicit_agent_name ~read_mcp_session_agent ~read_term_session_agent =
  let identity_session_prefix =
    let len = min 8 (String.length identity.Agent_identity.session_key) in
    if len = 0 then
      "anon"
    else
      String.sub identity.session_key 0 len
  in
  let generated_fallback_agent_name =
    Printf.sprintf "agent-%s" identity_session_prefix
  in
  match explicit_agent_name with
  | Some agent_name -> agent_name
  | None -> (
      match cached_resolved_agent with
      | Some cached -> cached
      | None ->
          if identity.Agent_identity.agent_name <> "" then
            identity.Agent_identity.agent_name
          else (
            match read_mcp_session_agent () with
            | Some name -> name
            | None ->
                if Option.is_some mcp_session_id then
                  generated_fallback_agent_name
                else (
                  match read_term_session_agent () with
                  | Some name ->
                      Log.Mcp.warn
                        "[deprecated] agent name resolved via /tmp TERM file — migrate to \
                         Agent_identity";
                      name
                  | None -> generated_fallback_agent_name)))

let resolve_auth_fallback_agent_name
    ~(config : Coord_utils_backend_setup.config)
    ~token ~has_explicit_agent_name
    agent_name =
  match token with
  | Some t
    when (not has_explicit_agent_name) && Agent_name_kind.is_transient agent_name
    -> (
      match Auth.resolve_agent_from_token config.base_path ~token:t with
      | Ok resolved -> resolved
      | Error err ->
          let error_kind = silent_auth_token_error_kind err in
          Log.Auth.warn
            "[silent:auth_token_resolve_error] agent=%s error_kind=%s - token resolve \
             failed, keeping caller alias"
            agent_name error_kind;
          Prometheus.inc_counter
            Prometheus.metric_silent_auth_token_resolve_error
            ~labels:[ "error_kind", error_kind; "agent", agent_name ]
            ();
          let mode = Auth_strict_mode.current () in
          let mode_label = Auth_strict_mode.to_label mode in
          (match mode with
          | Auth_strict_mode.Off -> ()
          | Auth_strict_mode.Dry_run | Auth_strict_mode.Strict ->
              Log.Auth.warn
                "[would_reject:auth_token_resolve_error] mode=%s agent=%s error_kind=%s \
                 - Phase B PR-2 will reject this request"
                mode_label agent_name error_kind;
              Prometheus.inc_counter
                Prometheus.metric_auth_strict_would_reject
                ~labels:
                  [ "mode", mode_label; "error_kind", error_kind; "agent", agent_name ]
                ());
          agent_name)
  | _ -> agent_name

let resolve_explicit_joined_alias ~config ~room_initialized ~log_mcp_exn
    ~has_explicit_agent_name agent_name =
  if has_explicit_agent_name && not (Nickname.is_generated_nickname agent_name)
  then (
    let resolved = Coord.resolve_agent_name config agent_name in
    if resolved <> agent_name then (
      try
        if room_initialized () then (
          try
            if Coord.is_agent_joined config ~agent_name:resolved then
              resolved
            else
              agent_name
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
              log_mcp_exn ~label:"is_agent_joined" exn;
              agent_name)
        else
          agent_name
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          log_mcp_exn ~label:"resolve_explicit_joined_alias" exn;
          agent_name)
    else
      agent_name)
  else
    agent_name

let resolve ~(config : Coord_utils_backend_setup.config) ~tool_name ~arguments ~identity ~cached_resolved_agent
    ~mcp_session_id ~auth_token ~internal_keeper_runtime ~room_initialized
    ~read_mcp_session_agent ~read_term_session_agent ~log_mcp_exn =
  let arg_get_string_opt key =
    match Safe_ops.json_string_opt key arguments with
    | Some "" -> None
    | other -> other
  in
  let explicit_agent_name = caller_agent_name_from_arguments arguments in
  let has_explicit_agent_name = Option.is_some explicit_agent_name in
  let agent_name =
    resolve_initial_agent_name ~identity ~cached_resolved_agent ~mcp_session_id
      ~explicit_agent_name ~read_mcp_session_agent ~read_term_session_agent
  in
  let token =
    match auth_token with
    | Some _ as token -> token
    | None -> arg_get_string_opt "token"
  in
  let verified_internal_keeper_runtime =
    internal_keeper_runtime
    &&
    match token with
    | Some raw -> Auth.verify_internal_keeper_token config.base_path ~token:raw
    | None -> false
  in
  let internal_keeper_runtime_tool =
    verified_internal_keeper_runtime
    && Tool_catalog.is_on_surface Tool_catalog.Keeper_internal tool_name
  in
  let owner_keeper_identity =
    match token with
    | None -> None
    | Some raw -> (
        match Auth.resolve_agent_from_token config.base_path ~token:raw with
        | Ok owner_name -> resolve_owner_keeper_identity config owner_name
        | Error msg ->
            Log.Auth.routine
              "owner_keeper_identity: token resolve failed: %s"
              (Masc_domain.masc_error_to_string msg);
            None)
  in
  let mode_gate_error =
    if
      (not internal_keeper_runtime_tool)
      && not (Tool_catalog.allow_direct_call tool_name)
    then
      Some (direct_call_block_message tool_name)
    else
      None
  in
  let persisted_agent_name () =
    if should_read_legacy_persisted_agent_name ~has_explicit_agent_name ~agent_name
    then
      match read_mcp_session_agent () with
      | Some n -> Some n
      | None ->
          if Option.is_some mcp_session_id then
            None
          else
            read_term_session_agent ()
    else
      None
  in
  let agent_name =
    match persisted_agent_name () with
    | Some persisted
      when Nickname.is_generated_nickname persisted
           && (not has_explicit_agent_name)
           && not (Nickname.is_generated_nickname agent_name) ->
        persisted
    | _ -> agent_name
  in
  let agent_name =
    resolve_auth_fallback_agent_name ~config ~token ~has_explicit_agent_name
      agent_name
  in
  let agent_name =
    resolve_explicit_joined_alias ~config ~room_initialized ~log_mcp_exn
      ~has_explicit_agent_name agent_name
  in
  {
    agent_name;
    token;
    has_explicit_agent_name;
    verified_internal_keeper_runtime;
    internal_keeper_runtime_tool;
    owner_keeper_identity;
    mode_gate_error;
  }
