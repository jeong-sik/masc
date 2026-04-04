(** Mcp_server_eio_execute — Core execute_tool_eio dispatcher

    Extracted from mcp_server_eio.ml.
    Contains the main tool dispatch function that resolves agent identity,
    checks authorization, and delegates to tool modules.
    Room concept removed: join/leave gating is gone.
*)

let log_mcp_exn = Mcp_server_eio_helpers.log_mcp_exn
let wait_for_message_eio = Mcp_server_eio_helpers.wait_for_message_eio

let is_ephemeral_agent_name name =
  String.length name >= 6 && String.sub name 0 6 = "agent-"

let is_transient_agent_name name =
  is_ephemeral_agent_name name || Nickname.is_generated_nickname name

let should_read_legacy_persisted_agent_name ~has_explicit_agent_name ~agent_name =
  (not has_explicit_agent_name) && is_ephemeral_agent_name agent_name

let direct_call_block_message name =
  if Tool_catalog.is_on_surface Tool_catalog.Keeper_internal name then
    let replacement_hint =
      match (Tool_catalog.metadata name).Tool_catalog.replacement with
      | Some replacement ->
          Printf.sprintf " Try `%s` instead." replacement
      | None -> ""
    in
    Printf.sprintf
      "Tool '%s' is keeper-internal and not callable from external MCP clients.%s"
      name replacement_hint
  else
    Printf.sprintf
      "Tool '%s' is hidden from the default tool surface and not callable directly."
      name

let execute_tool_eio ~sw ~clock ?mcp_session_id ?auth_token state ~name ~arguments =
  (* clock parameter used for Session_eio.wait_for_message *)
  (* mcp_session_id: HTTP MCP session ID for agent_name persistence across tool calls *)
  let module U = Yojson.Safe.Util in

  (* Defensive: ensure Eio global context is set for downstream OAS calls *)
  if Eio_context.get_switch_opt () = None then Eio_context.set_switch sw;

  (* Prometheus: count every inbound tool call *)
  Prometheus.record_request ();

  let config = state.Mcp_server.room_config in
  let registry = state.Mcp_server.session_registry in

  (* Fix 3: Cache room_initialized to avoid repeated stat syscalls.
     Updated after auto-init succeeds. *)
  let room_init_cached = ref (Room.is_initialized config) in

  (* Fix 4: Check resolved-name cache for fast identity resolution.
     On 2nd+ call in the same MCP session, the cached name lets us skip
     legacy /tmp file reads in the fallback paths below. *)
  let cached_resolved_agent =
    Option.bind mcp_session_id Agent_registry_eio.get_resolved_name
  in

  let identity = Agent_registry_eio.get_or_create_identity ?mcp_session_id arguments in
  Log.Mcp.debug "[Identity] %s" (Agent_identity.to_display_string identity);

  (* Deprecated: /tmp file-based agent identity. Use Agent_identity system instead.
     Kept for backward compat with pre-identity MCP clients. Remove when
     deprecation log shows zero hits over a release cycle. *)
  let read_mcp_session_agent () =
    match mcp_session_id with
    | None -> None
    | Some sid ->
        let file = Printf.sprintf "/tmp/.masc_agent_mcp_%s" sid in
        (try
          let name = Fs_compat.load_file file |> String.trim in
          if name = "" then None
          else begin
            Log.Mcp.warn "[deprecated] agent name resolved via /tmp file for session %s — migrate to Agent_identity" sid;
            Some name
          end
        with Sys_error _ | Eio.Io _ -> None)
  in

  (* Deprecated: write agent name to /tmp file. *)
  let write_mcp_session_agent agent_name =
    match mcp_session_id with
    | None -> ()
    | Some sid ->
        let file = Printf.sprintf "/tmp/.masc_agent_mcp_%s" sid in
        (try
          Fs_compat.save_file file agent_name
        with
        | Sys_error msg -> Log.Misc.warn "write_mcp_session_agent: %s" msg
        | Eio.Io _ as exn -> Log.Misc.warn "write_mcp_session_agent: %s" (Printexc.to_string exn))
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

  (* Resolve agent_name via Agent Identity system (primary) with legacy fallback. *)
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
    (* Fix 4: Use cached resolved name to skip legacy /tmp file reads *)
    if has_explicit_agent_name then
      raw_agent_name
    else match cached_resolved_agent with
    | Some cached -> cached
    | None ->
    if identity.Agent_identity.agent_name <> "" then
      identity.Agent_identity.agent_name
    else
      match read_mcp_session_agent () with
      | Some name -> name
      | None ->
          if Option.is_some mcp_session_id then
            generated_fallback_agent_name
          else
            let term_session_id = Option.value ~default:"" (Sys.getenv_opt "TERM_SESSION_ID") in
            let term_file = Printf.sprintf "/tmp/.masc_agent_%s" term_session_id in
            (try
              let name = Fs_compat.load_file term_file |> String.trim in
              if name <> "" then begin
                Log.Mcp.warn "[deprecated] agent name resolved via /tmp TERM file — migrate to Agent_identity";
                name
              end else raise Not_found
            with Sys_error _ | Not_found ->
              generated_fallback_agent_name)
  in

  let token =
    match arg_get_string_opt "token" with
    | Some t -> Some t
    | None -> auth_token
  in

  let mode_gate_error =
    if not (Tool_catalog.allow_direct_call name) then
      Some (direct_call_block_message name)
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
            let name = Fs_compat.load_file file |> String.trim in
            if name = "" then None else Some name
          with Sys_error _ -> None
  in

  let persisted_agent_name () =
    if should_read_legacy_persisted_agent_name ~has_explicit_agent_name ~agent_name
    then
      match read_mcp_session_agent () with
      | Some n -> Some n
      | None ->
          if Option.is_some mcp_session_id then None else read_term_session_agent ()
    else
      None
  in

  let agent_name =
    match persisted_agent_name () with
    | Some persisted
      when Nickname.is_generated_nickname persisted
           && not has_explicit_agent_name
           && not (Nickname.is_generated_nickname agent_name) ->
        persisted
    | _ -> agent_name
  in

  let agent_name =
    match token with
    (* Generated dashboard/session aliases should not outrank the
       credential owner encoded by the bearer token. *)
    | Some t when is_transient_agent_name agent_name ->
        (match Auth.resolve_agent_from_token config.base_path ~token:t with
         | Ok resolved -> resolved
         | Error _ -> agent_name)
    | _ -> agent_name
  in

  let agent_name =
    if has_explicit_agent_name && not (Nickname.is_generated_nickname agent_name) then
      let resolved = Room.resolve_agent_name config agent_name in
      if resolved <> agent_name then
        (* Room join concept removed — use resolved name directly *)
        resolved
      else
        agent_name
    else
      agent_name
  in

  (* Cache resolved agent_name for this session (Fix 4) *)
  (match mcp_session_id with
   | Some sid -> Agent_registry_eio.set_resolved_name sid agent_name
   | None -> ());
  match mode_gate_error with
  | Some msg -> (false, msg)
  | None ->
  (* Enforce tool authorization when enabled *)
  let auth_enabled = Auth.is_auth_enabled config.base_path in
  let auth_result =
    if auth_enabled then
      match Auth.authorize_tool_v2 config.base_path ~agent_name ~token ~tool_name:name with
      | Ok () -> Ok ()
      | Error err -> Error err
    else
      Ok ()
  in

  match auth_result with
  | Error err -> (false, Types.masc_error_to_string err)
  | Ok () ->

  let is_read_only = Tool_dispatch.is_read_only name in

  (* Auto-register session for non-read-only tools *)
  if agent_name <> "unknown" && not is_read_only then
    (try ignore (Session.register registry ~agent_name)
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn -> log_mcp_exn ~label:"session register (tool) failed" exn);

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
    if (not skip_heartbeat) && !room_init_cached then
      try
        ignore (Room.heartbeat config ~agent_name)
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
          Log.Misc.warn "heartbeat update skipped for %s on %s: %s"
            agent_name name (Printexc.to_string exn)
  end;

  (* === Fix 1: Tag-based lazy context dispatch ===
     O(1) tag lookup determines which module handles this tool.
     Only the matched module's context is created (1 out of 45+).
     Eliminates per-call 40+ context creation and ~210 Hashtbl.replace. *)

  (* Helper: create keeper context (shared by goals) *)
  let make_keeper_ctx () : _ Tool_keeper.context =
    { config; agent_name; sw; clock; proc_mgr = state.Mcp_server.proc_mgr; net = state.Mcp_server.net }
  in

  (* Dispatch a single module by tag — creates only that module's context *)
  let dispatch_by_tag (tag : Tool_dispatch.module_tag) : (bool * string) option =
    match Tool_dispatch.run_pre_hooks ~name ~args:arguments with
    | Some blocked -> Some (Tool_result.to_legacy blocked)
    | None -> match tag with
    | Mod_plan ->
        Tool_plan.dispatch { config } ~name ~args:arguments
    | Mod_operator ->
        let ctx = { Tool_operator.config; agent_name; sw; clock;
                    proc_mgr = state.Mcp_server.proc_mgr;
                    net = state.Mcp_server.net; mcp_session_id } in
        Tool_operator.dispatch ctx ~name ~args:arguments
    | Mod_command_plane ->
        let ctx : (_, _) Tool_command_plane.context =
          { config; agent_name; sw = Some sw; clock = Some clock;
            net = state.Mcp_server.net; mcp_state = Some state;
            mcp_session_id; auth_token } in
        Tool_command_plane.dispatch ctx ~name ~args:arguments
    | Mod_local_runtime ->
        Tool_local_runtime.dispatch { Tool_local_runtime.config; agent_name } ~name ~args:arguments
    | Mod_team_session ->
        let ctx = { Tool_team_session.config; agent_name; sw; clock;
                    proc_mgr = state.Mcp_server.proc_mgr;
                    net = state.Mcp_server.net } in
        Tool_team_session.dispatch ctx ~name ~args:arguments
    | Mod_voice ->
        Tool_voice.dispatch { agent_name; sw; clock; net = state.Mcp_server.net } ~name ~args:arguments
    | Mod_portal ->
        Tool_portal.dispatch { Tool_portal.config; agent_name } ~name ~args:arguments
    | Mod_worktree ->
        Tool_worktree.dispatch { Tool_worktree.config; agent_name } ~name ~args:arguments
    | Mod_code ->
        Tool_code.dispatch { Tool_code.config; agent_name } ~name ~args:arguments
    | Mod_code_write ->
        Tool_code_write.dispatch { Tool_code_write.config; agent_name } ~name ~args:arguments
    | Mod_a2a ->
        Tool_a2a.dispatch { Tool_a2a.config; agent_name } ~name ~args:arguments
    | Mod_handover ->
        let ctx : Tool_handover.context = { config; agent_name;
          fs = state.Mcp_server.fs; proc_mgr = state.Mcp_server.proc_mgr;
          sw = Some sw } in
        Tool_handover.dispatch ctx ~name ~args:arguments
    | Mod_relay ->
        Tool_relay.dispatch { Tool_relay.config; agent_name; sw;
          proc_mgr = state.Mcp_server.proc_mgr } ~name ~args:arguments
    | Mod_heartbeat ->
        Tool_heartbeat.dispatch { Tool_heartbeat.config; agent_name; sw; clock } ~name ~args:arguments
    | Mod_auth ->
        Tool_auth.dispatch { Tool_auth.config; agent_name } ~name ~args:arguments
    | Mod_run ->
        Tool_run.dispatch { Tool_run.config } ~name ~args:arguments
    | Mod_compact ->
        Tool_compact.dispatch ~name ~args:arguments
    | Mod_agent ->
        Tool_agent.dispatch { Tool_agent.config; agent_name } ~name ~args:arguments
    | Mod_task ->
        Tool_task.dispatch { Tool_task.config; agent_name; sw = Some sw }
          ~name ~args:arguments
    | Mod_room ->
        Tool_room.dispatch { Tool_room.config; agent_name } ~name ~args:arguments
    | Mod_control ->
        Tool_control.dispatch { Tool_control.config; agent_name } ~name ~args:arguments
    | Mod_improve_loop ->
        Tool_improve_loop.dispatch
          {
            Tool_improve_loop.config;
            agent_name;
            sw = Some sw;
            clock = Some clock;
            proc_mgr = state.Mcp_server.proc_mgr;
            net = state.Mcp_server.net;
          }
          ~name ~args:arguments
    | Mod_agent_timeline ->
        Tool_agent_timeline.dispatch { Tool_agent_timeline.config; agent_name } ~name ~args:arguments
    | Mod_misc ->
        Tool_misc.dispatch { Tool_misc.config; agent_name } ~name ~args:arguments
    | Mod_suspend ->
        Tool_suspend.dispatch { Tool_suspend.config; caller_agent = Some agent_name } ~name ~args:arguments
    | Mod_library ->
        Tool_library.dispatch { Tool_library.agent_name } ~name ~args:arguments
    | Mod_keeper ->
        Tool_keeper.dispatch (make_keeper_ctx ()) ~name ~args:arguments
    | Mod_repair_loop ->
        let ctx : _ Tool_repair_loop_types.context =
          {
            config;
            agent_name;
            sw = Some sw;
            clock = Some clock;
            proc_mgr = state.Mcp_server.proc_mgr;
          }
        in
        Tool_repair_loop.dispatch ctx ~name ~args:arguments
    | Mod_autoresearch ->
        let start_team_session ~goal ~operation_id ~loop_id:_ ~target_file:_
            ~program_note:_ =
          match state.Mcp_server.proc_mgr, state.Mcp_server.net with
          | None, _ -> Error "process_mgr not available"
          | Some _process_mgr, None -> Error "net not available for team session"
          | Some process_mgr, Some net ->
              let env = object
                method clock = clock
                method process_mgr = process_mgr
                method net = net
              end in
              Team_session_engine_eio.start_session ~sw ~env ~config
                ~created_by:agent_name ~goal ~duration_seconds:900
                ~execution_scope:Team_session_types.Limited_code_change
                ~checkpoint_interval_sec:60 ~min_agents:1
                ~scale_profile:Team_session_types.Scale_standard
                ~control_profile:
                  Team_session_types.Control_hierarchical_quality_v1
                ~orchestration_mode:Team_session_types.Assist
                ~communication_mode:Team_session_types.Comm_broadcast
                ~model_cascade:[]
                ~fallback_policy:Team_session_types.Fallback_cascade_then_task
                ~instruction_profile:Team_session_types.Profile_strict
                ~alert_channel:Team_session_types.Alert_broadcast
                ~auto_resume:true
                ~report_formats:
                  [ Team_session_types.Markdown; Team_session_types.Json ]
                ~agent_names:[] ~operation_id
        in
        let ctx : Tool_autoresearch.context = { base_path = config.base_path;
          agent_name = Some agent_name; start_operation = None;
          start_team_session = Some start_team_session;
          config = Some config; sw = Some sw; clock = Some clock } in
        Tool_autoresearch.dispatch ctx ~name ~args:arguments
    | Mod_shard ->
        let (ok, json) = Tool_shard.execute name arguments in
        Some (ok, Yojson.Safe.to_string json)
    | Mod_inline ->
        let inline_ctx : Tool_inline_dispatch.context = {
          config; agent_name; registry; state; sw; clock; arguments;
          mcp_session_id; write_mcp_session_agent;
          wait_for_message = (fun registry ~agent_name ~timeout ->
            wait_for_message_eio ~clock registry ~agent_name ~timeout);
          governance_defaults = Mcp_server_eio_governance.governance_defaults;
          save_governance = Mcp_server_eio_governance.save_governance;
          load_mcp_sessions = Mcp_server_eio_governance.load_mcp_sessions;
          save_mcp_sessions = Mcp_server_eio_governance.save_mcp_sessions;
        } in
        Tool_inline_dispatch.dispatch inline_ctx ~name
  in

  (* Primary dispatch: mint token at I/O boundary, then O(1) tag lookup.
     Tool_token validates the name exists in the tag registry (Parse, Don't
     Validate). If mint fails, the tool is truly unknown. *)
  match Tool_dispatch.mint_token ~name with
  | Error reason ->
      (false, Printf.sprintf "Unknown tool: %s (%s)" name reason)
  | Ok _token ->
      (* Token proves the name is registered in at least one registry.
         lookup_tag None after mint is a registry inconsistency (tool in
         handler registry but not tag registry), not a user error. *)
      let tag_result =
        match Tool_dispatch.lookup_tag name with
        | Some tag -> dispatch_by_tag tag
        | None -> None
      in
      (match tag_result with
       | Some result -> result
       | None ->
           Log.Mcp.warn "registry inconsistency: %s minted but no tag" name;
           (false, Printf.sprintf "Unknown tool: %s (registry inconsistency)" name))
