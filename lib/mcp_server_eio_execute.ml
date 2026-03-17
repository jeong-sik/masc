(** Mcp_server_eio_execute — Core execute_tool_eio dispatcher

    Extracted from mcp_server_eio.ml.
    Contains the main tool dispatch function that resolves agent identity,
    checks authorization, auto-joins, and delegates to tool modules.
*)

let log_mcp_exn = Mcp_server_eio_helpers.log_mcp_exn
let wait_for_message_eio = Mcp_server_eio_helpers.wait_for_message_eio

let execute_tool_eio ~sw ~clock ?mcp_session_id ?auth_token state ~name ~arguments =
  (* clock parameter used for Session_eio.wait_for_message *)
  (* mcp_session_id: HTTP MCP session ID for agent_name persistence across tool calls *)
  let module U = Yojson.Safe.Util in

  (* Prometheus: count every inbound tool call *)
  Prometheus.record_request ();

  let config = state.Mcp_server.room_config in
  let registry = state.Mcp_server.session_registry in

  (* === Agent Identity Resolution via Agent_registry_eio === *)
  (* This replaces file-based session persistence with proper identity tracking *)
  let identity = Agent_registry_eio.get_or_create_identity ?mcp_session_id arguments in
  Log.Mcp.debug "[Identity] %s" (Agent_identity.to_display_string identity);

  (* Legacy helper for backward compatibility - reads from file if identity not in args *)
  let read_mcp_session_agent () =
    match mcp_session_id with
    | None -> None
    | Some sid ->
        let file = Printf.sprintf "/tmp/.masc_agent_mcp_%s" sid in
        try
          let ic = open_in file in
          let name =
            Common.protect ~module_name:"mcp_server_eio" ~finally_label:"finalizer"
              ~finally:(fun () -> close_in_noerr ic)
              (fun () -> input_line ic)
          in
          if name = "" then None else Some name
        with Sys_error _ | End_of_file -> None
  in

  (* Legacy helper - write to file for backward compat with non-identity-aware tools *)
  let write_mcp_session_agent agent_name =
    match mcp_session_id with
    | None -> ()
    | Some sid ->
        let file = Printf.sprintf "/tmp/.masc_agent_mcp_%s" sid in
        try
          let oc = open_out file in
          Common.protect ~module_name:"mcp_server_eio" ~finally_label:"finalizer"
            ~finally:(fun () -> close_out_noerr oc)
            (fun () -> output_string oc agent_name)
        with Sys_error msg ->
          Log.Misc.warn "write_mcp_session_agent: %s" msg
  in

  (* Helper to get values from JSON arguments - delegates to Safe_ops *)
  let arg_get_string key default =
    Safe_ops.json_string ~default key arguments
  in
  let arg_get_string_opt key =
    match Safe_ops.json_string_opt key arguments with
    | Some "" -> None
    | other -> other
  in

  (* Resolve agent_name via Agent Identity system (primary) with legacy fallback.
     Agent_registry_eio.get_or_create_identity already resolved identity above.
     Use identity.agent_name as the canonical source. *)
  let raw_agent_name = arg_get_string "agent_name" "" in
  let has_explicit_agent_name = raw_agent_name <> "" && raw_agent_name <> "unknown" in
  let identity_session_prefix =
    let len = min 8 (String.length identity.session_key) in
    if len = 0 then "anon" else String.sub identity.session_key 0 len
  in
  let generated_fallback_agent_name =
    Printf.sprintf "agent-%s" identity_session_prefix
  in
  let agent_name =
    (* Priority: explicit arg > identity > legacy file-based *)
    if has_explicit_agent_name then
      raw_agent_name
    else if identity.Agent_identity.agent_name <> "" then
      identity.Agent_identity.agent_name
    else
      (* Legacy fallback for edge cases *)
      match read_mcp_session_agent () with
      | Some name -> name
      | None ->
          if Option.is_some mcp_session_id then
            generated_fallback_agent_name
          else
            let term_session_id = Option.value ~default:"" (Sys.getenv_opt "TERM_SESSION_ID") in
            let term_file = Printf.sprintf "/tmp/.masc_agent_%s" term_session_id in
            (try
              let ic = open_in term_file in
              let name =
                Common.protect ~module_name:"mcp_server_eio" ~finally_label:"finalizer"
                  ~finally:(fun () -> close_in_noerr ic)
                  (fun () -> input_line ic)
              in
              if name <> "" then name else raise Not_found
            with Sys_error _ | End_of_file | Not_found ->
              generated_fallback_agent_name)
  in

  let token =
    match arg_get_string_opt "token" with
    | Some t -> Some t
    | None -> auth_token
  in

  let room_path = Room.masc_dir config in
  let _mode_config = Config.load room_path in

  let mode_gate_error =
    if not (Tool_catalog.allow_direct_call name) then
      Some
        (Printf.sprintf
           "Tool '%s' is hidden from the default tool surface and not callable directly."
           name)
    else
      None
  in

  let read_term_session_agent () =
    if Option.is_some mcp_session_id then
      None
    else
      match Sys.getenv_opt "TERM_SESSION_ID" with
      | None -> None
      | Some sid ->
          let file = Printf.sprintf "/tmp/.masc_agent_%s" sid in
          try
            let ic = open_in file in
            let name =
              Common.protect ~module_name:"mcp_server_eio" ~finally_label:"finalizer"
                ~finally:(fun () -> close_in_noerr ic)
                (fun () -> input_line ic)
            in
            if name = "" then None else Some name
          with Sys_error _ | End_of_file -> None
  in

  let persisted_agent_name () =
    match read_mcp_session_agent () with
    | Some n -> Some n
    | None ->
        if Option.is_some mcp_session_id then None else read_term_session_agent ()
  in

  (* If no explicit agent_name was provided and we already have a persisted
     generated nickname, prefer it for backward compatibility.
     IMPORTANT: explicit agent_name must win to allow multi-agent spawning. *)
  let agent_name =
    match persisted_agent_name () with
    | Some persisted
      when Nickname.is_generated_nickname persisted
           && not has_explicit_agent_name
           && not (Nickname.is_generated_nickname agent_name) ->
        persisted
    | _ -> agent_name
  in

  let is_ephemeral_agent_name name =
    String.length name >= 6 && String.sub name 0 6 = "agent-"
  in

  let agent_name =
    match token with
    | Some t when is_ephemeral_agent_name agent_name ->
        (match Auth.resolve_agent_from_token config.base_path ~token:t with
         | Ok resolved -> resolved
         | Error _ -> agent_name)
    | _ -> agent_name
  in

  (* Explicit non-nickname aliases (e.g., "alpha-agent") should resolve to an
     existing generated nickname if one is already joined. This prevents
     claim/start/done calls from drifting across different nicknames. *)
  let agent_name =
    if has_explicit_agent_name && not (Nickname.is_generated_nickname agent_name) then
      let resolved = Room.resolve_agent_name config agent_name in
      if resolved <> agent_name then
        try
          if Room.is_agent_joined config ~agent_name:resolved then
            resolved
          else
            agent_name
        with exn ->
          log_mcp_exn ~label:__FUNCTION__ exn;
          agent_name
      else
        agent_name
    else
      agent_name
  in
  match mode_gate_error with
  | Some msg -> (false, msg)
  | None ->
  (* Enforce tool authorization when enabled *)
  let auth_enabled = Auth.is_auth_enabled config.base_path in
  let auth_result =
    if auth_enabled then
      match Auth.authorize_tool config.base_path ~agent_name ~token ~tool_name:name with
      | Ok () -> Ok ()
      | Error err -> Error err
    else
      Ok ()
  in

  match auth_result with
  | Error err -> (false, Types.masc_error_to_string err)
  | Ok () ->
  let extract_nickname_from_join_result ~fallback result =
    try
      let prefix = "  Nickname: " in
      let start_idx =
        let idx = ref 0 in
        while !idx < String.length result - String.length prefix &&
              String.sub result !idx (String.length prefix) <> prefix do
          incr idx
        done;
        !idx + String.length prefix
      in
      let end_idx = String.index_from result start_idx '\n' in
      String.sub result start_idx (end_idx - start_idx)
    with Not_found | Invalid_argument _ -> fallback
  in

  let write_term_session_agent nickname =
    if Option.is_some mcp_session_id then
      ()
    else
      match Sys.getenv_opt "TERM_SESSION_ID" with
      | None -> ()
      | Some sid ->
          let file = Printf.sprintf "/tmp/.masc_agent_%s" sid in
          (try
            let oc = open_out file in
            Common.protect ~module_name:"mcp_server_eio" ~finally_label:"finalizer"
              ~finally:(fun () -> close_out_noerr oc)
              (fun () -> output_string oc nickname)
          with e ->
            Log.Misc.error "Failed to write agent file %s: %s"
              file (Printexc.to_string e))
  in

  (* Auto-init/auto-join for better UX.
     - Auto-init only when auth is disabled (avoid side effects in secured rooms).
     - Auto-join when allowed by auth (and safe for token-based auth). *)
  let join_required = Tool_dispatch.is_join_required name in

  let init_error =
    if (not auth_enabled) && join_required && not (Room.is_initialized config) then
      (try
         ignore (Room.init config ~agent_name:None);
         None
       with Invalid_argument msg -> Some msg
          | Sys_error msg -> Some msg
          | Yojson.Json_error msg -> Some msg
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Some (Printexc.to_string exn))
    else
      None
  in
  match init_error with
  | Some msg ->
      (false, Printf.sprintf "❌ %s" msg)
  | None ->

  let is_read_only = Tool_dispatch.is_read_only name in

  let can_auto_join =
    if (not join_required) || agent_name = "unknown" then
      false
    else if not auth_enabled then
      true
    else
      (* If per-agent tokens are required, only auto-join when agent_name already
         looks like a stable nickname. Otherwise Room.join would generate a new
         nickname, breaking token verification for subsequent calls. *)
      let auth_cfg = Auth.load_auth_config config.base_path in
      if auth_cfg.require_token && not (Nickname.is_generated_nickname agent_name) then
        false
      else
        match Auth.authorize_tool config.base_path ~agent_name ~token ~tool_name:"masc_join" with
        | Ok () -> true
        | Error _ -> false
  in

  let agent_name =
    if can_auto_join then begin
      let room_initialized = Room.is_initialized config in
      let is_joined =
        if room_initialized then
          try Room.is_agent_joined config ~agent_name
          with Sys_error _ | Yojson.Json_error _ | Invalid_argument _ -> false
        else
          false
      in
      if is_joined then
        agent_name
      else begin
        let join_result = Room.join config ~agent_name ~capabilities:[] () in
        let nickname = extract_nickname_from_join_result ~fallback:agent_name join_result in
        Log.Mcp.info "Auto-joined for %s: %s -> %s" name agent_name nickname;
        (* Persist nickname so subsequent calls can use it. *)
        write_mcp_session_agent nickname;
        write_term_session_agent nickname;
        (try ignore (Session.register registry ~agent_name:nickname)
         with exn -> log_mcp_exn ~label:"session register (nickname) failed" exn);
        (* Prometheus + Telemetry: track auto-join *)
        Prometheus.inc_gauge "masc_active_agents" ();
        (match state.Mcp_server.fs with
         | Some fs ->
             (try Telemetry_eio.track_agent_joined ~fs config ~agent_id:nickname ()
              with exn ->
                Log.Telemetry.debug "track_agent_joined (auto): %s" (Printexc.to_string exn))
         | None -> ());
        nickname
      end
    end else
      agent_name
  in

  (* Auto-register session for non-read-only tools *)
  if agent_name <> "unknown" && not is_read_only then
    (try ignore (Session.register registry ~agent_name)
     with exn -> log_mcp_exn ~label:"session register (tool) failed" exn);

  (* Log tool call *)
  Log.Mcp.debug "[%s] %s" agent_name name;

  (* Update activity for any tool call *)
  if agent_name <> "unknown" then begin
    Session.update_activity registry ~agent_name ();
    (* Keep read-only/fast tools non-blocking; heartbeat is best-effort. *)
    let skip_heartbeat =
      is_read_only
      || Tool_catalog.is_placeholder name
      || match Tool_catalog.implementation_status name with
         | Tool_catalog.Simulation -> true
         | Tool_catalog.Real | Tool_catalog.Adapter | Tool_catalog.Placeholder ->
             false
    in
    if (not skip_heartbeat) && Room.is_initialized config then
      try
        ignore (Room.heartbeat config ~agent_name)
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
          Log.Misc.warn "heartbeat update skipped for %s on %s: %s"
            agent_name name (Printexc.to_string exn)
  end;

  (* Check if agent must join first *)
  let room_initialized = Room.is_initialized config in
  let is_joined =
    if room_initialized then
      (* Some tools (e.g., masc_init) must run before initialization.
         Guard the join check to avoid raising and crashing the server. *)
      try Room.is_agent_joined config ~agent_name
      with Sys_error _ | Yojson.Json_error _ -> false
    else
      false
  in

  (* Debug: log join check *)
  Log.Misc.debug "tool=%s agent_name=%s join_required=%b room_initialized=%b is_joined=%b"
    name agent_name join_required room_initialized is_joined;

  if join_required && not room_initialized then
    (false, Printf.sprintf
      "⚠️ MASC room not initialized.\n\n💡 Workflow: masc_init → masc_join → masc_status → %s\n📚 See: @~/me/instructions/masc-workflow.md\n[DEBUG] agent_name=%s room_initialized=%b"
      name agent_name room_initialized)
  else if join_required && not is_joined then
    (false, Printf.sprintf
      "❌ Join required: Call masc_join first before using %s.\n\n💡 Workflow: masc_join → masc_status → %s\n📚 See: @~/me/instructions/masc-workflow.md\n[DEBUG] agent_name=%s is_joined=%b"
      name name agent_name is_joined)
  else

  (* Delegate to extracted tool modules first *)
  let simple_ctx_config = { Tool_plan.config } in
  let simple_ctx_run = { Tool_run.config } in
  let simple_ctx_team_session =
    { Tool_team_session.config; agent_name; sw; clock; proc_mgr = state.Mcp_server.proc_mgr }
  in
  let simple_ctx_operator =
    {
      Tool_operator.config;
      agent_name;
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      mcp_session_id;
    }
  in
  let simple_ctx_command_plane : (_, _) Tool_command_plane.context =
    {
      config;
      agent_name;
      sw = Some sw;
      clock = Some clock;
      net = state.Mcp_server.net;
      mcp_state = Some state;
      mcp_session_id;
      auth_token;
    }
  in
  let simple_ctx_cache = { Tool_cache.config } in
  let simple_ctx_tempo = { Tool_tempo.config; agent_name } in
  let simple_ctx_mitosis =
    Tool_mitosis.make_context_with_eio
      ~config
      ~sw
      ~proc_mgr:state.Mcp_server.proc_mgr
      ~clock
  in
  let simple_ctx_portal : Tool_portal.context = { config; agent_name } in
  let simple_ctx_worktree : Tool_worktree.context = { config; agent_name } in
  let simple_ctx_code_swarm : Tool_code_swarm.context = { config; agent_name } in
  let simple_ctx_code : Tool_code.context = { config; agent_name } in
  let simple_ctx_vote : Tool_vote.context = { config; agent_name } in
  let simple_ctx_social : Tool_social.context = { config; agent_name } in
  let simple_ctx_council : Tool_council.context = {
    base_path = config.base_path;
    agent_name;
    room_config = Some config;
  } in
  let simple_ctx_a2a : Tool_a2a.context = { config; agent_name } in
  let handover_ctx : Tool_handover.context = {
    config; agent_name;
    fs = state.Mcp_server.fs;
    proc_mgr = state.Mcp_server.proc_mgr;
    sw = Some sw;
  } in
  let simple_ctx_relay : Tool_relay.context = { config; agent_name; sw; proc_mgr = state.Mcp_server.proc_mgr } in
  let simple_ctx_goals : Tool_goals.context =
    {
      config;
      agent_name;
      call_keeper_msg =
        Some
          (fun keeper_args ->
            let keeper_ctx : _ Tool_keeper.context =
              {
                config;
                agent_name;
                sw;
                clock;
                proc_mgr = state.Mcp_server.proc_mgr;
              }
            in
            match
              Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_msg"
                ~args:keeper_args
            with
            | Some result -> result
            | None -> (false, "masc_keeper_msg dispatch unavailable"));
    }
  in
  let simple_ctx_heartbeat = { Tool_heartbeat.config; agent_name; sw; clock } in
  let simple_ctx_encryption : Tool_encryption.context = { state } in
  let simple_ctx_auth : Tool_auth.context = { config; agent_name } in
  let simple_ctx_hat : Tool_hat.context = { config; agent_name } in
  let simple_ctx_audit : Tool_audit.context = { config } in
  let simple_ctx_rate_limit : Tool_rate_limit.context = { config; agent_name; registry } in
  let simple_ctx_cost : Tool_cost.context = { agent_name } in
  let simple_ctx_walph : (_ Tool_walph.context, string) result =
    match state.Mcp_server.net with
    | Some net -> Ok ({ config; agent_name; net; clock } : _ Tool_walph.context)
    | None -> Error "walph requires net (server_state.net is None)"
  in
  let simple_ctx_agent : Tool_agent.context = { config; agent_name } in
  let simple_ctx_task : Tool_task.context = { config; agent_name } in
  let simple_ctx_room : Tool_room.context = { config; agent_name } in
  let simple_ctx_control : Tool_control.context = { config; agent_name } in
  let simple_ctx_misc : Tool_misc.context = { config; agent_name } in
  let simple_ctx_agent_timeline : Tool_agent_timeline.context = { config; agent_name } in
  let simple_ctx_llama : Tool_llama.context = { config; agent_name } in
  let simple_ctx_voice : _ Tool_voice.context =
    { agent_name; sw; clock; net = state.Mcp_server.net }
  in
  let simple_ctx_suspend : Tool_suspend.context = { config; caller_agent = Some agent_name } in
  let simple_ctx_library : Tool_library.context = { agent_name } in
  let simple_ctx_mdal : Tool_mdal.context = {
    agent_name;
    config = Some config;
    sw = Some sw;
    proc_mgr = state.Mcp_server.proc_mgr;
    worker_runner = None;
    clock = Some clock;
  } in
  let simple_ctx_perpetual : Tool_perpetual.context = {
    agent_name;
    start_loop = Some (fun loop_state loop_config ->
      Eio.Fiber.fork ~sw (fun () ->
        try
          Perpetual_loop.run ~config:loop_config ~state:loop_state
        with exn ->
          log_mcp_exn ~label:(Printf.sprintf "perpetual loop crashed for %s" loop_state.Perpetual_loop.trace_id) exn));
    sw = Some sw;
    proc_mgr = state.Mcp_server.proc_mgr;
    room_config = Some config;
  } in
  let simple_ctx_keeper : _ Tool_keeper.context =
    {
      config;
      agent_name;
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
    }
  in
  let trpg_keeper_call ~name:keeper_name ~message ~timeout_sec :
      Tool_trpg.keeper_call_result =
    let keeper_args =
      `Assoc
        [
          ("name", `String keeper_name);
          ("message", `String message);
          ("timeout_sec", `Float timeout_sec);
        ]
    in
    (* Eio outer timeout includes LLM time + protocol overhead (serialization,
       network). Add 10s grace to avoid racing the LLM timeout. *)
    let eio_timeout = timeout_sec +. (Env_config_runtime.Timeout.llm_grace_sec *. 2.0) in
    try
      Eio.Time.with_timeout_exn clock eio_timeout (fun () ->
          match
            Tool_keeper.dispatch simple_ctx_keeper ~name:"masc_keeper_msg"
              ~args:keeper_args
          with
          | None -> `Error "masc_keeper_msg dispatch unavailable"
          | Some (true, body) -> (
              try `Ok (Yojson.Safe.from_string body)
              with Yojson.Json_error e ->
                `Error (Printf.sprintf "keeper returned invalid json: %s" e))
          | Some (false, msg) -> `Error msg)
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Eio.Time.Timeout -> `Timeout
    | exn -> `Error (Printexc.to_string exn)
  in
  let trpg_keeper_probe ~name:keeper_name : Tool_trpg.keeper_probe_result =
    let keeper_args =
      `Assoc [ ("name", `String keeper_name); ("fast", `Bool true) ]
    in
    try
      Eio.Time.with_timeout_exn clock 5.0 (fun () ->
          match
            Tool_keeper.dispatch simple_ctx_keeper ~name:"masc_keeper_status"
              ~args:keeper_args
          with
          | None -> `Error "masc_keeper_status dispatch unavailable"
          | Some (true, _body) -> `Ok
          | Some (false, msg) -> `Error msg)
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Eio.Time.Timeout -> `Error "timeout"
    | exn -> `Error (Printexc.to_string exn)
  in
  let trpg_dm_voice_emit ~agent_id ~message ~provider : Tool_trpg.dm_voice_emit_result =
    match state.Mcp_server.net with
    | None -> Error "trpg voice requires net (server_state.net is None)"
    | Some net ->
    let provider =
      match provider |> Option.map String.trim with
      | Some p when p <> "" && not (String.equal (String.lowercase_ascii p) "auto") ->
          Some p
      | _ -> None
    in
    Voice_bridge.agent_speak ~sw ~clock ~net ~agent_id ~message ?provider ()
  in
  let trpg_store = Trpg_store.make_sqlite ~base_dir:config.base_path in
  let simple_ctx_trpg : Tool_trpg.context =
    {
      store = trpg_store;
      agent_name;
      keeper_call = Some trpg_keeper_call;
      keeper_probe = Some trpg_keeper_probe;
      dm_voice_emit = Some trpg_dm_voice_emit;
    }
  in
  let simple_ctx_protocol : Tool_protocol_game_view.context =
    {
      config;
      store = trpg_store;
      agent_name;
      trpg_keeper_call = Some trpg_keeper_call;
      trpg_keeper_probe = Some trpg_keeper_probe;
      trpg_dm_voice_emit = Some trpg_dm_voice_emit;
    }
  in

  (* === V2 Dispatch: O(1) Hashtbl-based central dispatch ===
     When MASC_DISPATCH_V2=1, register all schema-exporting modules
     and try O(1) lookup first.  Falls through to the legacy chain
     for inline tools and modules without exported schemas.

     NOTE: Registration happens on every call because handler closures
     capture per-call state (e.g. simple_ctx_keeper holds the request's
     Eio.Switch [sw]).  Hashtbl.replace is idempotent and the cost
     (~210 replace ops) is negligible vs. the legacy 40-module sequential
     match chain.  The primary win is O(1) dispatch lookup. *)
  let v2_result =
    if Tool_dispatch.v2_enabled then begin
      let reg = Tool_dispatch.register_module in
      reg ~schemas:Tool_operator.schemas
        ~handler:(fun ~name ~args -> Tool_operator.dispatch simple_ctx_operator ~name ~args);
      reg ~schemas:Tool_command_plane.schemas
        ~handler:(fun ~name ~args -> Tool_command_plane.dispatch simple_ctx_command_plane ~name ~args);
      reg ~schemas:Tool_llama.schemas
        ~handler:(fun ~name ~args -> Tool_llama.dispatch simple_ctx_llama ~name ~args);
      reg ~schemas:Tool_team_session.schemas
        ~handler:(fun ~name ~args -> Tool_team_session.dispatch simple_ctx_team_session ~name ~args);
      reg ~schemas:Tool_voice.schemas
        ~handler:(fun ~name ~args -> Tool_voice.dispatch simple_ctx_voice ~name ~args);
      reg ~schemas:Tool_protocol_game_view.schemas
        ~handler:(fun ~name ~args -> Tool_protocol_game_view.dispatch simple_ctx_protocol ~name ~args);
      reg ~schemas:Tool_goals.schemas
        ~handler:(fun ~name ~args -> Tool_goals.dispatch simple_ctx_goals ~name ~args);
      reg ~schemas:Tool_perpetual.schemas
        ~handler:(fun ~name ~args -> Tool_perpetual.dispatch simple_ctx_perpetual ~name ~args);
      reg ~schemas:Tool_mdal.schemas
        ~handler:(fun ~name ~args -> Tool_mdal.dispatch simple_ctx_mdal ~name ~args);
      reg ~schemas:Tool_keeper.schemas
        ~handler:(fun ~name ~args -> Tool_keeper.dispatch simple_ctx_keeper ~name ~args);
      reg ~schemas:Tool_trpg.schemas
        ~handler:(fun ~name ~args -> Tool_trpg.dispatch simple_ctx_trpg ~name ~args);
      reg ~schemas:Tool_agent_timeline.schemas
        ~handler:(fun ~name ~args -> Tool_agent_timeline.dispatch simple_ctx_agent_timeline ~name ~args);
      (* B-0a: newly registered modules with domain schema files *)
      reg ~schemas:Tool_plan.schemas
        ~handler:(fun ~name ~args -> Tool_plan.dispatch simple_ctx_config ~name ~args);
      reg ~schemas:Tool_portal.schemas
        ~handler:(fun ~name ~args -> Tool_portal.dispatch simple_ctx_portal ~name ~args);
      reg ~schemas:Tool_worktree.schemas
        ~handler:(fun ~name ~args -> Tool_worktree.dispatch simple_ctx_worktree ~name ~args);
      reg ~schemas:Tool_code_swarm.schemas
        ~handler:(fun ~name ~args -> Tool_code_swarm.dispatch simple_ctx_code_swarm ~name ~args);
      reg ~schemas:Tool_auth.schemas
        ~handler:(fun ~name ~args -> Tool_auth.dispatch simple_ctx_auth ~name ~args);
      reg ~schemas:Tool_agent.schemas
        ~handler:(fun ~name ~args -> Tool_agent.dispatch simple_ctx_agent ~name ~args);
      reg ~schemas:Tool_room.schemas
        ~handler:(fun ~name ~args -> Tool_room.dispatch simple_ctx_room ~name ~args);
      Tool_dispatch.dispatch ~name ~args:arguments
    end else None
  in
  match v2_result with
  | Some result -> result
  | None ->

  (* Chain through all extracted tool modules *)
  match Tool_plan.dispatch simple_ctx_config ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_run.dispatch simple_ctx_run ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_operator.dispatch simple_ctx_operator ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_command_plane.dispatch simple_ctx_command_plane ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_llama.dispatch simple_ctx_llama ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_team_session.dispatch simple_ctx_team_session ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_voice.dispatch simple_ctx_voice ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_cache.dispatch simple_ctx_cache ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_tempo.dispatch simple_ctx_tempo ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_mitosis.dispatch simple_ctx_mitosis ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_portal.dispatch simple_ctx_portal ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_worktree.dispatch simple_ctx_worktree ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_code_swarm.dispatch simple_ctx_code_swarm ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_code.dispatch simple_ctx_code ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_vote.dispatch simple_ctx_vote ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_social.dispatch simple_ctx_social ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_council.dispatch simple_ctx_council ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_protocol_game_view.dispatch simple_ctx_protocol ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_a2a.dispatch simple_ctx_a2a ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_handover.dispatch handover_ctx ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_relay.dispatch simple_ctx_relay ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_goals.dispatch simple_ctx_goals ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_heartbeat.dispatch simple_ctx_heartbeat ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_encryption.dispatch simple_ctx_encryption ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_auth.dispatch simple_ctx_auth ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_hat.dispatch simple_ctx_hat ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_audit.dispatch simple_ctx_audit ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_rate_limit.dispatch simple_ctx_rate_limit ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_cost.dispatch simple_ctx_cost ~name ~args:arguments with
  | Some result -> result
  | None ->
  if String.length name >= 11 && String.equal (String.sub name 0 11) "masc_walph_" then
    (match simple_ctx_walph with
     | Error msg -> (false, msg)
     | Ok ctx ->
       match Tool_walph.dispatch ctx ~name ~args:arguments with
       | Some result -> result
       | None -> (false, Printf.sprintf "Unknown Walph tool: %s" name))
  else
  match Tool_agent.dispatch simple_ctx_agent ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_task.dispatch simple_ctx_task ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_room.dispatch simple_ctx_room ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_control.dispatch simple_ctx_control ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_agent_timeline.dispatch simple_ctx_agent_timeline ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_misc.dispatch simple_ctx_misc ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_suspend.dispatch simple_ctx_suspend ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_library.dispatch simple_ctx_library ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_keeper.dispatch simple_ctx_keeper ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_perpetual.dispatch simple_ctx_perpetual ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_mdal.dispatch simple_ctx_mdal ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_trpg.dispatch simple_ctx_trpg ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_notifications.dispatch state.Mcp_server.session_registry ~agent_name ~name arguments with
  | Some result -> result
  | None ->
  (* Tool_gardener returns result directly, not option - wrap it *)
  if String.length name >= 14 && String.sub name 0 14 = "masc_gardener_" then
    Tool_gardener.dispatch () name arguments
  else

  (* Delegate remaining inline tools to Tool_inline_dispatch *)
  let inline_ctx : Tool_inline_dispatch.context = {
    config;
    agent_name;
    registry;
    state;
    sw;
    clock;
    arguments;
    mcp_session_id;
    write_mcp_session_agent;
    wait_for_message = (fun registry ~agent_name ~timeout ->
      wait_for_message_eio ~clock registry ~agent_name ~timeout);
    governance_defaults = Mcp_server_eio_governance.governance_defaults;
    save_governance = Mcp_server_eio_governance.save_governance;
    load_mcp_sessions = Mcp_server_eio_governance.load_mcp_sessions;
    save_mcp_sessions = Mcp_server_eio_governance.save_mcp_sessions;
  } in
  match Tool_inline_dispatch.dispatch inline_ctx ~name with
  | Some result -> result
  | None ->
      (false, Printf.sprintf "Unknown tool: %s" name)

  (* --- Removed inline match block: extracted to lib/tool_inline_dispatch.ml --- *)
  (* Original block handled: masc_lock, masc_unlock, masc_set_room, masc_join,
     masc_leave, masc_bounded_run, masc_broadcast, masc_messages, masc_listen,
     masc_who, masc_verify_*, masc_mcp_session, masc_cancellation,
     masc_subscription, masc_progress, masc_interrupt, masc_approve,
     masc_reject, masc_pending_interrupts, masc_branch, masc_governance_set,
     masc_spawn, masc_memento_mori, masc_episode_flush, masc_episode_list,
     masc_self_introspect, masc_recall_search, masc_board_*, lodge_*,
     masc_convo_* *)

