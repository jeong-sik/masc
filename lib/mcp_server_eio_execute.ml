(** Mcp_server_eio_execute — Core execute_tool_eio dispatcher

    Extracted from mcp_server_eio.ml.
    Contains the main tool dispatch function that resolves agent identity,
    checks authorization, auto-joins, and delegates to tool modules.
*)

let log_mcp_exn = Mcp_server_eio_helpers.log_mcp_exn
let wait_for_message_eio = Mcp_server_eio_helpers.wait_for_message_eio

let resolve_join_state ~room_initialized ~join_required ~agent_name ~check_join =
  if room_initialized && join_required && agent_name <> "unknown" then
    try check_join ()
    with Sys_error _ | Yojson.Json_error _ -> false
  else
    false

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
  let room_init_cached = ref (Coord.is_initialized config) in

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
      let resolved = Coord.resolve_agent_name config agent_name in
      if resolved <> agent_name then
        try
          if !room_init_cached then
            (try
              if Coord.is_agent_joined config ~agent_name:resolved then
                resolved
              else
                agent_name
            with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
              log_mcp_exn ~label:"is_agent_joined" exn;
              agent_name)
          else
            agent_name
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          log_mcp_exn ~label:__FUNCTION__ exn;
          agent_name
      else
        agent_name
    else
      agent_name
  in

  (* Cache resolved agent_name for this session (Fix 4) *)
  (match mcp_session_id with
   | Some sid -> Agent_registry_eio.set_resolved_name sid agent_name
   | None -> ());
  let is_system_internal_tool =
    Tool_catalog.is_on_surface Tool_catalog.System_internal name
  in
  let preview ?(max_len = 240) text =
    if String.length text <= max_len then text
    else String.sub text 0 max_len ^ "..."
  in
  let argument_keys_json =
    match arguments with
    | `Assoc fields ->
        fields
        |> List.map fst
        |> List.sort_uniq String.compare
        |> List.map (fun key -> `String key)
    | _ -> []
  in
  let with_system_internal_audit ~agent_name ((success, message) as result) =
    if is_system_internal_tool then (
      let error_msg =
        if success then None else Some (preview message)
      in
      let details =
        `Assoc
          [
            ("source", `String "mcp_server_eio_execute");
            ("visible_in_tools_list", `Bool (Tool_catalog.is_visible name));
            ("allow_direct_call", `Bool (Tool_catalog.allow_direct_call name));
            ("mcp_session_id_present", `Bool (Option.is_some mcp_session_id));
            ("argument_keys", `List argument_keys_json);
          ]
      in
      Audit_log.log_system_internal_tool_call config ~agent_id:agent_name
        ~tool_name:name ~success ~error_msg ~details
        ?trace_id:(Otel_spans.current_trace_id ()) ());
    result
  in
  match mode_gate_error with
  | Some msg -> with_system_internal_audit ~agent_name (false, msg)
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
  | Error err ->
      with_system_internal_audit ~agent_name
        (false, Types.masc_error_to_string err)
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
            Fs_compat.save_file file nickname
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | e ->
            Log.Misc.error "Failed to write agent file %s: %s"
              file (Printexc.to_string e))
  in

  (* Auto-init/auto-join for better UX.
     - Auto-init only when auth is disabled (avoid side effects in secured rooms).
     - Auto-join when allowed by auth (and safe for token-based auth). *)
  let join_required = Tool_dispatch.is_join_required name in

  let init_error =
    if (not auth_enabled) && join_required && not !room_init_cached then
      (try
         let (_init_msg : string) = Coord.init config ~agent_name:None in
         room_init_cached := true;  (* Fix 3: update cache after successful init *)
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
      with_system_internal_audit ~agent_name
        (false, Printf.sprintf "❌ %s" msg)
  | None ->

  let is_read_only = Tool_dispatch.is_read_only name in

  let can_auto_join =
    if (not join_required) || agent_name = "unknown" then
      false
    else if Option.is_none mcp_session_id then
      (* Sessionless requests (no Mcp-Session-Id header) should not auto-join.
         Without a session, each request gets a new ephemeral agent name,
         causing orphan agent proliferation in the room. *)
      false
    else if not auth_enabled then
      true
    else
      (* If per-agent tokens are required, only auto-join when agent_name already
         looks like a stable nickname. Otherwise Coord.join would generate a new
         nickname, breaking token verification for subsequent calls. *)
      let auth_cfg = Auth.load_auth_config config.base_path in
      if auth_cfg.require_token && not (Nickname.is_generated_nickname agent_name) then
        false
      else
        match Auth.authorize_tool_v2 config.base_path ~agent_name ~token ~tool_name:"masc_join" with
        | Ok () -> true
        | Error _ -> false
  in

  let agent_name =
    if can_auto_join then begin
      (* Fix 3: use cached room_initialized *)
      let is_joined =
        if !room_init_cached then
          try Coord.is_agent_joined config ~agent_name
          with Sys_error _ | Yojson.Json_error _ | Invalid_argument _ -> false
        else
          false
      in
      if is_joined then
        agent_name
      else begin
        let join_result = Coord.join config ~agent_name ~capabilities:[] () in
        let nickname = extract_nickname_from_join_result ~fallback:agent_name join_result in
        Log.Mcp.info "Auto-joined for %s: %s -> %s" name agent_name nickname;
        (* Persist nickname so subsequent calls can use it. *)
        write_mcp_session_agent nickname;
        write_term_session_agent nickname;
        (try ignore (Session.register registry ~agent_name:nickname)
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn -> log_mcp_exn ~label:"session register (nickname) failed" exn);
        nickname
      end
    end else
      agent_name
  in

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
        ignore (Coord.heartbeat config ~agent_name)
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
          Log.Misc.warn "heartbeat update skipped for %s on %s: %s"
            agent_name name (Printexc.to_string exn)
  end;

  (* Check if agent must join first — Fix 3: use cached value *)
  let room_initialized = !room_init_cached in
  let is_joined =
    resolve_join_state
      ~room_initialized
      ~join_required
      ~agent_name
      ~check_join:(fun () -> Coord.is_agent_joined config ~agent_name)
  in

  (* Debug: log join check *)
  Log.Misc.debug "tool=%s agent_name=%s join_required=%b room_initialized=%b is_joined=%b"
    name agent_name join_required room_initialized is_joined;

  if join_required && not room_initialized then
    with_system_internal_audit ~agent_name
      (false, Printf.sprintf
         "⚠️ MASC room not initialized.\n\n💡 Workflow: masc_init → masc_join → masc_status → %s\n📚 See: @~/me/instructions/masc-workflow.md\n[DEBUG] agent_name=%s room_initialized=%b"
         name agent_name room_initialized)
  else if join_required && not is_joined then
    with_system_internal_audit ~agent_name
      (false, Printf.sprintf
         "❌ Join required: Call masc_join first before using %s.\n\n💡 Workflow: masc_join → masc_status → %s\n📚 See: @~/me/instructions/masc-workflow.md\n[DEBUG] agent_name=%s is_joined=%b"
         name name agent_name is_joined)
  else

  (* === Fix 1: Tag-based lazy context dispatch ===
     O(1) tag lookup determines which module handles this tool.
     Only the matched module's context is created (1 out of 45+).
     Eliminates per-call 40+ context creation and ~210 Hashtbl.replace. *)

  (* Helper: create keeper context (shared by goals) *)
  let make_keeper_ctx () : _ Tool_keeper.context =
    { config; agent_name; sw; clock; proc_mgr = state.Mcp_server.proc_mgr; net = state.Mcp_server.net }
  in

  (* Dispatch a single module by tag — creates only that module's context.
     Pre-hooks may coerce arguments (e.g. OAS type coercion: "42" -> 42). *)
  let dispatch_by_tag (tag : Tool_dispatch.module_tag) : (bool * string) option =
    match Tool_dispatch.run_pre_hooks ~name ~args:arguments with
    | (Some blocked, _) -> Some (Tool_result.to_legacy blocked)
    | (None, coerced_args) -> match tag with
    | Mod_plan ->
        Tool_plan.dispatch { config } ~name ~args:coerced_args
    | Mod_operator ->
        let ctx = { Tool_operator.config; agent_name; sw; clock;
                    proc_mgr = state.Mcp_server.proc_mgr;
                    net = state.Mcp_server.net; mcp_session_id } in
        Tool_operator.dispatch ctx ~name ~args:coerced_args
    | Mod_local_runtime ->
        Tool_local_runtime.dispatch { Tool_local_runtime.config; agent_name } ~name ~args:coerced_args
    | Mod_worktree ->
        Tool_worktree.dispatch { Tool_worktree.config; agent_name } ~name ~args:coerced_args
    | Mod_code ->
        Tool_code.dispatch { Tool_code.config; agent_name } ~name ~args:coerced_args
    | Mod_code_write ->
        Tool_code_write.dispatch { Tool_code_write.config; agent_name } ~name ~args:coerced_args
    | Mod_a2a ->
        Tool_a2a.dispatch { Tool_a2a.config; agent_name } ~name ~args:coerced_args
    (* Mod_handover, Mod_heartbeat, Mod_auth removed: tools pruned *)
    | Mod_run ->
        Tool_run.dispatch { Tool_run.config } ~name ~args:coerced_args
    | Mod_compact ->
        Tool_compact.dispatch ~name ~args:coerced_args
    | Mod_agent ->
        Tool_agent.dispatch { Tool_agent.config; agent_name } ~name ~args:coerced_args
    | Mod_task ->
        Tool_task.dispatch { Tool_task.config; agent_name; sw = Some sw }
          ~name ~args:coerced_args
    | Mod_room ->
        Tool_coord.dispatch { Tool_coord.config; agent_name } ~name ~args:coerced_args
    | Mod_control ->
        Tool_control.dispatch { Tool_control.config; agent_name } ~name ~args:coerced_args
    | Mod_agent_timeline ->
        Tool_agent_timeline.dispatch { Tool_agent_timeline.config; agent_name } ~name ~args:coerced_args
    | Mod_misc ->
        Tool_misc.dispatch { Tool_misc.config; agent_name } ~name ~args:coerced_args
    | Mod_suspend ->
        Tool_suspend.dispatch { Tool_suspend.config; caller_agent = Some agent_name } ~name ~args:coerced_args
    | Mod_library ->
        Tool_library.dispatch { Tool_library.agent_name } ~name ~args:coerced_args
    | Mod_keeper ->
        Tool_keeper.dispatch (make_keeper_ctx ()) ~name ~args:coerced_args
    (* Mod_repair_loop removed: tools pruned *)
    | Mod_autoresearch ->
        let ctx : Tool_autoresearch.context = { base_path = config.base_path;
          agent_name = Some agent_name; start_operation = None;
          config = Some config; sw = Some sw; clock = Some clock } in
        Tool_autoresearch.dispatch ctx ~name ~args:coerced_args
    | Mod_shard ->
        let (ok, json) = Tool_shard.execute name coerced_args in
        Some (ok, Yojson.Safe.to_string json)
    | Mod_inline ->
        let inline_ctx : Tool_inline_dispatch.context = {
          config; agent_name; registry; state; sw; clock; arguments = coerced_args;
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
      with_system_internal_audit ~agent_name
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
       | Some result -> with_system_internal_audit ~agent_name result
       | None ->
           Log.Mcp.warn "registry inconsistency: %s minted but no tag" name;
           with_system_internal_audit ~agent_name
             (false,
              Printf.sprintf "Unknown tool: %s (registry inconsistency)" name))
