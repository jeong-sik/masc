(** Mcp_server_eio_execute — Core execute_tool_eio dispatcher

    Extracted from mcp_server_eio.ml.
    Contains the main tool dispatch function that resolves agent identity,
    checks authorization, auto-joins, and delegates to tool modules.
*)

let log_mcp_exn = Mcp_server_eio_helpers.log_mcp_exn
let wait_for_message_eio = Mcp_server_eio_helpers.wait_for_message_eio

(* #10699 Family A — "Join required" surfaces 28 / 24h events for
   masc_transition + masc_claim_next while the underlying keeper had
   joined under its canonical name at boot via
   [ensure_keeper_room_presence]. Rotation aliases (e.g.
   [nick0cave-happy-shark] vs canonical [keeper-nick0cave-agent])
   carry the join entry under the canonical name only;
   [Coord.is_agent_joined] does prefix matching against on-disk agent
   files but cannot project an alias back to the canonical without
   the [Keeper_identity] vocabulary that owns that mapping.

   When the raw [agent_name] check fails, retry once using the
   canonical [keeper_name] from
   [Keeper_identity.normalize_all_names]. The normalisation is gated
   by [canonical_keeper_name] inside [Keeper_identity], so an
   unrelated external caller ("alice-fake-bear") returns
   [Persona_not_found] and falls through to the original [false] —
   the alias-bridge only fires when the input is recognisably a
   keeper-form name.

   [check_join] is now parameterised on the candidate name so we can
   re-issue the lookup against the canonical form without rebuilding
   the closure environment. *)
let resolve_join_state ~room_initialized ~join_required ~agent_name
    ~base_path ~check_join =
  if not (room_initialized && join_required) then false
  else if agent_name = "unknown" then false
  else
    let try_candidate name = name <> agent_name && check_join name in
    try
      if check_join agent_name then true
      else
        match
          Keeper_identity.normalize_all_names
            ~input_agent_name:agent_name
            ~base_path
            ~check_persona:false
            ~check_credential:false
            ()
        with
        | Ok bundle ->
            (* Try the persona-level [keeper_name] first (e.g.
               [nick0cave]), then the canonical agent-form alias
               that [ensure_keeper_room_presence] writes to disk
               (e.g. [keeper-nick0cave-agent]). [check_join]'s own
               prefix-matching in [Coord.is_agent_joined] handles
               the file-on-disk lookup. *)
            try_candidate bundle.keeper_name
            || try_candidate
                 (Printf.sprintf "keeper-%s-agent" bundle.keeper_name)
        | Error _ -> false
    with Sys_error _ | Yojson.Json_error _ -> false

let is_ephemeral_agent_name name =
  Base.String.is_prefix name ~prefix:"agent-"

let is_transient_agent_name name =
  is_ephemeral_agent_name name
  || Nickname.is_dictionary_generated_nickname name

let silent_auth_token_error_kind = function
  | Types.InvalidToken _ -> "token_mismatch"
  | Types.TokenExpired _ -> "token_expired"
  | Types.Unauthorized _ -> "unauthorized"
  | _ -> "other"

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

let execute_tool_eio ~sw ~clock ?(profile = Mcp_server_eio_tool_profile.Full)
    ?mcp_session_id ?auth_token ?(internal_keeper_runtime = false) state ~name
    ~arguments =
  (* clock parameter used for Session_eio.wait_for_message *)
  (* mcp_session_id: HTTP MCP session ID for agent_name persistence across tool calls *)
  let module U = Yojson.Safe.Util in

  (* Defensive: refresh Eio global context for downstream helpers that still
     consult the ambient switch/clock during a request. Tests may leave a
     finished switch in the global slot between runs, so keep it aligned with
     the current request scope. *)
  Eio_context.set_switch sw;
  Eio_context.set_clock clock;

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
            (match Safe_ops.protect ~default:None (fun () ->
               let name = Fs_compat.load_file term_file |> String.trim in
               if name <> "" then Some name else None)
             with
             | Some name ->
                 Log.Mcp.warn "[deprecated] agent name resolved via /tmp TERM file — migrate to Agent_identity";
                 name
             | None -> generated_fallback_agent_name)
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
    && Tool_catalog.is_on_surface Tool_catalog.Keeper_internal name
  in

  let resolve_owner_keeper_identity owner_name =
    let candidates =
      [
        Keeper_types.canonical_keeper_name owner_name;
        Keeper_types.canonical_keeper_name_from_agent_name owner_name;
      ]
      |> List.filter_map (function
           | Some value when String.trim value <> "" -> Some (String.trim value)
           | _ -> None)
      |> List.sort_uniq String.compare
    in
    let rec loop = function
      | [] -> None
      | candidate :: rest -> (
          match Keeper_types.read_meta_resolved config candidate with
          | Ok (Some (resolved_name, meta)) ->
              Some
                ( resolved_name,
                  Option.map Keeper_id.Uid.to_string meta.Keeper_types.keeper_id )
          | Ok None -> loop rest
          | Error _ -> loop rest)
    in
    loop candidates
  in

  let owner_keeper_identity =
    match token with
    | None -> None
    | Some raw -> (
        match Auth.resolve_agent_from_token config.base_path ~token:raw with
        | Ok owner_name -> resolve_owner_keeper_identity owner_name
        | Error _ -> None)
  in

  let mode_gate_error =
    if
      (not internal_keeper_runtime_tool)
      && not (Tool_catalog.allow_direct_call name)
    then
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
    (* Explicit agent_name is the caller's SSOT for this request.
       Rewriting an explicit generated alias to the bearer-token owner
       makes mutation paths operate under a different identity than the
       one shown in join/status/debug output, which is exactly the
       #8892 joined/debug/credential-route drift. Keep the explicit
       alias and let auth preflight reject it if the token does not
       authorize that identity. We only fall back to token ownership
       when the request did not explicitly name an agent. *)
    | Some t when (not has_explicit_agent_name) && is_transient_agent_name agent_name ->
        (match Auth.resolve_agent_from_token config.base_path ~token:t with
         | Ok resolved -> resolved
         | Error err ->
             (* PR-I: surface the silent fallback. The pre-#9786 branch silently
                kept the caller-supplied alias when the bearer token did not
                resolve to any credential, masking identity drift in production.
                Emit a warn + counter so operators can grep [silent:auth_token]. *)
             let error_kind = silent_auth_token_error_kind err in
             Log.Auth.warn
               "[silent:auth_token_resolve_error] agent=%s error_kind=%s - token resolve \
                failed, keeping caller alias"
               agent_name
               error_kind;
             Prometheus.inc_counter
               Prometheus.metric_silent_auth_token_resolve_error
               ~labels:[ ("error_kind", error_kind); ("agent", agent_name) ]
               ();
             (* Phase A F2 (2026-04-27): pair the silent counter with a
                [would_reject] emission so operators can measure how many of
                these fall-throughs would be rejected under MASC_AUTH_STRICT.
                Behavior is unchanged: this PR only adds telemetry + a flag
                surface so Phase B PR-2 can flip [Strict] safely. *)
             let mode = Auth_strict_mode.current () in
             let mode_label = Auth_strict_mode.to_label mode in
             (match mode with
              | Auth_strict_mode.Off -> ()
              | Auth_strict_mode.Dry_run | Auth_strict_mode.Strict ->
                  Log.Auth.warn
                    "[would_reject:auth_token_resolve_error] mode=%s agent=%s \
                     error_kind=%s - Phase B PR-2 will reject this request"
                    mode_label agent_name error_kind;
                  Prometheus.inc_counter
                    Prometheus.metric_auth_strict_would_reject
                    ~labels:
                      [ ("mode", mode_label);
                        ("error_kind", error_kind);
                        ("agent", agent_name);
                      ]
                    ());
             agent_name)
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
    String_util.utf8_safe ~max_bytes:(max_len + 3) ~suffix:"..." text |> String_util.to_string
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
  let dedupe_string_list values =
    values
    |> List.map String.trim
    |> List.filter (fun value -> value <> "")
    |> List.sort_uniq String.compare
  in
  let tool_authorized_for_request tool_name =
    (not auth_enabled)
    ||
    match
      Auth.authorize_tool_v2 config.base_path ~agent_name ~token ~tool_name
    with
    | Ok () -> true
    | Error _ -> false
  in
  let profile_tool_names =
    Mcp_server_eio_tool_profile.tool_schemas_for_profile state profile
    |> List.map (fun (schema : Types.tool_schema) -> schema.name)
    |> List.filter (fun tool_name ->
           Tool_catalog.allow_direct_call tool_name
           && Mcp_server_eio_tool_profile.tool_allowed_in_profile state profile
                tool_name
           && tool_authorized_for_request tool_name)
  in
  let keeper_tool_names =
    let candidates =
      [
        Keeper_types.canonical_keeper_name agent_name;
        Keeper_types.canonical_keeper_name_from_agent_name agent_name;
      ]
      |> List.filter_map Fun.id
      |> List.sort_uniq String.compare
    in
    let rec loop = function
      | [] -> []
      | keeper_name :: rest -> (
          match Keeper_types.read_meta_resolved config keeper_name with
          | Ok (Some (_, meta)) ->
            Keeper_tool_policy.keeper_allowed_tool_names meta
          | Ok None | Error _ -> loop rest)
    in
    loop candidates
  in
  let caller_tool_names =
    Some (dedupe_string_list (profile_tool_names @ keeper_tool_names))
  in
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
      let end_idx = match String.index_from_opt result start_idx '\n' with
        | Some idx -> idx
        | None -> String.length result
      in
      String.sub result start_idx (end_idx - start_idx)
    with Invalid_argument _ -> fallback
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
        let join_result =
          Coord.join config ~agent_name ~capabilities:[]
            ~keeper_name:(Option.map fst owner_keeper_identity)
            ~keeper_id:(Option.bind owner_keeper_identity snd)
            ()
        in
        let nickname = extract_nickname_from_join_result ~fallback:agent_name join_result in
        Log.Mcp.info "Auto-joined for %s: %s -> %s" name agent_name nickname;
        (* Persist nickname so subsequent calls can use it. *)
        write_mcp_session_agent nickname;
        write_term_session_agent nickname;
        let (_ : Session.session) = Session.register registry ~agent_name:nickname in
        nickname
      end
    end else
      agent_name
  in

  (match owner_keeper_identity with
   | Some (keeper_name, keeper_id) when agent_name <> "unknown" && !room_init_cached ->
       (try
          Coord_task.update_local_agent_state config ~agent_name (fun agent ->
              let meta =
                match agent.meta with
                | Some existing ->
                    {
                      existing with
                      keeper_name = Some keeper_name;
                      keeper_id;
                    }
                | None ->
                    {
                      session_id = "";
                      agent_type = agent.agent_type;
                      pid = None;
                      hostname = None;
                      tty = None;
                      worktree = None;
                      parent_task = None;
                      keeper_name = Some keeper_name;
                      keeper_id;
                    }
              in
              { agent with meta = Some meta })
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
            Log.Mcp.warn "keeper owner stamp skipped for %s: %s"
              agent_name (Printexc.to_string exn))
   | Some _ | None -> ());

  (* Auto-register session for non-read-only tools *)
  if agent_name <> "unknown" && not is_read_only then begin
    let (_ : Session.session) = Session.register registry ~agent_name in
    ()
  end;

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
    if (not skip_heartbeat) && !room_init_cached then begin
      try
        let (_ : string) = Coord.heartbeat config ~agent_name in
        ()
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
          Log.Misc.warn "heartbeat update skipped for %s on %s: %s"
            agent_name name (Printexc.to_string exn)
    end
  end;

  (* Check if agent must join first — Fix 3: use cached value *)
  let room_initialized = !room_init_cached in
  let is_joined =
    resolve_join_state
      ~room_initialized
      ~join_required
      ~agent_name
      ~base_path:config.base_path
      ~check_join:(fun candidate ->
        Coord.is_agent_joined config ~agent_name:candidate)
  in

  (* Debug: log join check *)
  Log.Misc.debug "tool=%s agent_name=%s join_required=%b room_initialized=%b is_joined=%b"
    name agent_name join_required room_initialized is_joined;

  if join_required && not room_initialized then begin
    (* #9770: surface guard fires as a fleet-wide metric so
       operators can see which (tool, agent) pairs repeatedly skip
       masc_join without log-scraping. *)
    Prometheus.inc_counter
      Prometheus.metric_tool_join_required_guard
      ~labels:[ ("tool", name);
                ("agent_name", agent_name);
                ("reason", "room_uninitialized") ]
      ();
    with_system_internal_audit ~agent_name
      (false, Printf.sprintf
         "⚠️ MASC room not initialized.\n\n💡 Fastest: masc_start(path=\"<project>\") — one-step init+join, then call %s.\n💡 Alternative: masc_init → masc_join → masc_status → %s\n📚 See: @~/me/instructions/masc-workflow.md\n[DEBUG] agent_name=%s room_initialized=%b"
         name name agent_name room_initialized)
  end
  else if join_required && not is_joined then begin
    Prometheus.inc_counter
      Prometheus.metric_tool_join_required_guard
      ~labels:[ ("tool", name);
                ("agent_name", agent_name);
                ("reason", "agent_not_joined") ]
      ();
    with_system_internal_audit ~agent_name
      (false, Printf.sprintf
         "❌ Join required before using %s.\n\n💡 Fastest: masc_start(path=\"<project>\") — one-step join with room scope.\n💡 Alternative: masc_join → masc_status → %s\n📚 See: @~/me/instructions/masc-workflow.md\n[DEBUG] agent_name=%s is_joined=%b"
         name name agent_name is_joined)
  end
  else (

  (* === Fix 1: Tag-based lazy context dispatch ===
     O(1) tag lookup determines which module handles this tool.
     Only the matched module's context is created (1 out of 45+).
     Eliminates per-call 40+ context creation and ~210 Hashtbl.replace. *)

  (* Helper: create keeper tool boundary context (shared by goals) *)
  let make_keeper_tool_ctx () =
    Keeper_tool_boundary.create ~config ~agent_name ~sw ~clock
      ~proc_mgr:state.Mcp_server.proc_mgr ~net:state.Mcp_server.net
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
        Tool_task.dispatch ?agent_tool_names:caller_tool_names
          { Tool_task.config; agent_name; sw = Some sw } ~name
          ~args:coerced_args
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
        Keeper_tool_boundary.dispatch (make_keeper_tool_ctx ()) ~name
          ~args:coerced_args
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

  (* #9784: enrich Unknown tool errors with closest-name suggestions so the
     LLM can self-correct on the next turn rather than re-emit the same
     hallucinated name. Suggestions come from a similarity scan of the
     full tool registry. *)
  let format_unknown_tool_error ~reason =
    let suggestions = Tool_dispatch.find_similar_names ~query:name () in
    match suggestions with
    | [] -> Printf.sprintf "Unknown tool: %s (%s)" name reason
    | xs ->
        Printf.sprintf "Unknown tool: %s — did you mean: %s? (%s)"
          name (String.concat ", " xs) reason
  in
  let internal_keeper_meta_of_agent () =
    match Keeper_registry.find_by_agent_name agent_name with
    | Some (entry : Keeper_registry.registry_entry)
      when String.equal entry.base_path config.base_path ->
        Ok entry.meta
    | Some _ | None ->
        let candidates =
          [
            Keeper_types.canonical_keeper_name_from_agent_name agent_name;
            Keeper_types.canonical_keeper_name agent_name;
          ]
          |> List.filter_map (function
               | Some value when String.trim value <> "" ->
                   Some (String.trim value)
               | _ -> None)
          |> List.sort_uniq String.compare
        in
        let rec loop = function
          | [] ->
              Error
                (Printf.sprintf
                   "Internal keeper runtime request is not bound to a known \
                    keeper agent: %s"
                   agent_name)
          | candidate :: rest -> (
              match Keeper_types.read_meta_resolved config candidate with
              | Ok (Some (_resolved_name, meta)) -> Ok meta
              | Ok None -> loop rest
              | Error msg -> Error msg)
        in
        loop candidates
  in
  let dispatch_internal_keeper_runtime_tool () =
    match Tool_dispatch.run_pre_hooks ~name ~args:arguments with
    | (Some blocked, _) -> Some (Tool_result.to_legacy blocked)
    | (None, coerced_args) -> (
        match internal_keeper_meta_of_agent () with
        | Error msg -> Some (false, msg)
        | Ok meta ->
            let ctx_work =
              Keeper_exec_context.create ~system_prompt:""
                ~max_tokens:(Keeper_config.keeper_unified_max_tokens ())
            in
            let turn_sandbox_runtime =
              match meta.Keeper_types.sandbox_profile with
              | Keeper_types.Docker ->
                  Some
                    (Keeper_turn_sandbox_runtime.create ~config ~meta
                       ~network_mode:meta.network_mode ())
              | Keeper_types.Local -> None
            in
            let turn_sandbox_runtime_git =
              match meta.Keeper_types.sandbox_profile with
              | Keeper_types.Docker ->
                  if Env_config_keeper.KeeperSandbox.hard_mode () then
                    None
                  else
                    Some
                      (Keeper_turn_sandbox_runtime.create ~config ~meta
                         ~network_mode:Keeper_types.Network_inherit ())
              | Keeper_types.Local -> None
            in
            let cleanup () =
              (match turn_sandbox_runtime with
               | Some runtime -> Keeper_turn_sandbox_runtime.cleanup runtime
               | None -> ());
              match turn_sandbox_runtime_git with
              | Some runtime -> Keeper_turn_sandbox_runtime.cleanup runtime
              | None -> ()
            in
            let exec_cache = Some (Masc_exec.Exec_cache.create ()) in
            let result =
              Fun.protect
                ~finally:cleanup
                (fun () ->
                  Keeper_exec_tools.execute_keeper_tool_call_with_outcome
                    ~config ~meta ~ctx_work ?turn_sandbox_runtime
                    ?turn_sandbox_runtime_git ~exec_cache ~name
                    ~input:coerced_args ())
            in
            let success =
              match result.Keeper_exec_tools.outcome with
              | `Success -> true
              | `Failure -> false
            in
            Some (success, result.raw_output))
  in
  (* Primary dispatch: mint token at I/O boundary, then O(1) tag lookup.
     Tool_token validates the name exists in the tag registry (Parse, Don't
     Validate). If mint fails, the tool is truly unknown. *)
  match
    if internal_keeper_runtime_tool then
      dispatch_internal_keeper_runtime_tool ()
    else
      None
  with
  | Some result ->
      with_system_internal_audit ~agent_name result
  | None -> match Tool_dispatch.mint_token ~name with
  | Error reason ->
      with_system_internal_audit ~agent_name
        (false, format_unknown_tool_error ~reason)
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
              Printf.sprintf "Unknown tool: %s (registry inconsistency)" name)))
