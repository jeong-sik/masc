(** Mcp_server_eio_execute — Core execute_tool_eio dispatcher

    Extracted from mcp_server_eio.ml.
    Contains the main tool dispatch function that resolves agent identity,
    checks authorization, session-binds, and delegates to tool modules.
*)

let wait_for_message_eio = Mcp_server_eio_helpers.wait_for_message_eio

let caller_agent_name_from_arguments arguments =
  Mcp_server_eio_caller_identity.caller_agent_name_from_arguments arguments
;;

let resolve_bind_state ~workspace_initialized ~bind_required ~agent_name ~check_join =
  workspace_initialized
  && bind_required
  && not (String.equal agent_name "unknown")
  && check_join agent_name
;;

let lane_access_for_caller ~config
    (caller : Mcp_server_eio_caller_identity.t) =
  if caller.verified_internal_keeper_runtime then
    match Keeper_meta_store.read_meta_resolved config caller.agent_name with
    | Ok (Some (keeper_name, _)) -> Lane_addon_sources.Keeper keeper_name
    | Ok None | Error _ -> Lane_addon_sources.Unauthenticated
  else
    let token = caller.token in
    let owner_keeper_identity = caller.owner_keeper_identity in
    match token with
    | None -> Lane_addon_sources.Unauthenticated
    | Some raw ->
      (match Auth.find_credential_by_token config.base_path ~token:raw with
       | Ok { Masc_domain.role = Masc_domain.Admin; _ } ->
         Lane_addon_sources.Operator_configuration
       | Ok { Masc_domain.role = Masc_domain.Worker; _ } ->
         (match owner_keeper_identity with
          | Some (keeper_name, _) -> Lane_addon_sources.Keeper keeper_name
          | None -> Lane_addon_sources.Unauthenticated)
       | Ok { Masc_domain.role = Masc_domain.Player; _ } | Error _ ->
         Lane_addon_sources.Unauthenticated)

;;

let browser_principal_for_caller ~config (caller:Mcp_server_eio_caller_identity.t) =
  let access=lane_access_for_caller ~config caller in
  if caller.verified_internal_keeper_runtime then
    match access with
    | Lane_addon_sources.Keeper name -> Lane_addon_call_context.Keeper name
    | Operator_configuration|Unauthenticated -> Lane_addon_call_context.Anonymous
  else match caller.token with
    | None -> Lane_addon_call_context.Anonymous
    | Some token ->
        match Auth.find_credential_by_token config.base_path ~token with
        | Error _ -> Lane_addon_call_context.Anonymous
        | Ok credential ->
            match access with
            | Lane_addon_sources.Keeper name -> Lane_addon_call_context.Keeper name
            | Operator_configuration|Unauthenticated ->
                Lane_addon_call_context.Authenticated_agent credential.agent_name
;;

let board_reader_for_caller ~config (caller : Mcp_server_eio_caller_identity.t) =
  let keeper_reader name =
    match Keeper_meta_store.read_effective_meta_presence config name with
    | Ok (Keeper_meta_store.Meta_present meta) -> Keeper_board_audience.reader_for_keeper meta
    | Ok (Keeper_meta_store.Meta_absent | Keeper_meta_store.Meta_not_current _) | Error _ -> Masc_board_handlers.Board_access.Anonymous
  in
  if caller.verified_internal_keeper_runtime then keeper_reader caller.agent_name
  else match caller.token with
    | Some token ->
      (match Auth.find_credential_by_token config.Workspace.base_path ~token with
       | Ok credential ->
         (match credential.Masc_domain.role with
          | Masc_domain.Admin -> Masc_board_handlers.Board_access.Operator
          | Masc_domain.Worker | Masc_domain.Player ->
            (match caller.owner_keeper_identity with
             | Some (name, _) -> keeper_reader name
             | None -> Masc_board_handlers.Board_access.named credential.agent_name))
       | Error _ -> Masc_board_handlers.Board_access.Anonymous)
    | None ->
      let auth = Auth.load_auth_config config.base_path in
      if auth.Masc_domain.enabled && auth.require_token then Masc_board_handlers.Board_access.Anonymous
      else Masc_board_handlers.Board_access.Operator
;;

let execute_tool_eio
      ~sw
      ~clock
      ~(workspace_scope : Mcp_server.workspace_scope)
      ?(profile = Mcp_server_eio_tool_profile.Full)
      ?mcp_session_id
      ?invocation_ref
      ?auth_token
      ?(internal_keeper_runtime = false)
      ?on_caller_resolved
      state
      ~name
      ~arguments
  =
  (* clock parameter used for wait_for_message_eio *)
  (* mcp_session_id: HTTP MCP session ID for in-process identity continuity. *)
  (* Defensive: bind fiber-local request switch and refresh ambient clock for
     downstream helpers that consult them during a request, without overwriting
     the process-wide root switch (RFC-0107 / Issue #33570). *)
  Eio_context.with_turn_switch sw (fun () ->
  Eio_context.set_clock clock;
  (* Otel_metric_store: count every inbound tool call *)
  Otel_metric_store.record_request ();
  let config = workspace_scope.config in
  let registry = state.Mcp_server.session_registry in
  (* Fix 3: Cache workspace_initialized to avoid repeated stat syscalls. *)
  let workspace_init_cached = Workspace.is_initialized config in
  (* Fix 4: Check resolved-name cache for fast identity resolution.
     On 2nd+ call in the same MCP session, the cached name preserves the
     nickname selected by the prior session binding without relying on sidecar files. *)
  let cached_resolved_agent =
    Option.bind mcp_session_id Client_registry_eio.get_resolved_name
  in
  let identity = Client_registry_eio.get_or_create_identity ?mcp_session_id arguments in
  Log.Mcp.debug "[Identity] %s" (Client_identity.to_display_string identity);
  let record_mcp_session_agent ~is_ephemeral agent_name =
    match mcp_session_id with
    | None -> ()
    | Some sid -> Client_registry_eio.set_resolved_name sid agent_name ~is_ephemeral
  in
  let profile_permitted =
    Mcp_server_eio_tool_profile.tool_allowed_in_profile state profile name
  in
  (* [tool_allowed_in_profile] already checks [Tool_catalog.allow_direct_call]
     for [Full] as well as profile membership for restricted profiles. When
     [profile_permitted] is [true], pass [Restricted_profile] so
     [Mcp_server_eio_caller_identity.resolve] does not re-evaluate
     [Tool_catalog.allow_direct_call] a second time. *)
  let direct_call_authority =
    if profile_permitted
    then Mcp_server_eio_caller_identity.Restricted_profile
    else Mcp_server_eio_caller_identity.Catalog_policy
  in
  let caller_identity =
    Mcp_server_eio_caller_identity.resolve ~config ~tool_name:name ~arguments
      ~identity ~cached_resolved_agent ~auth_token ~internal_keeper_runtime
      ~direct_call_authority ~workspace_initialized:(fun () -> workspace_init_cached)
      ~log_mcp_exn:Mcp_server_eio_helpers.log_mcp_exn
  in
  Option.iter (fun observe -> observe caller_identity) on_caller_resolved;
  let agent_name = caller_identity.agent_name in
  let token = caller_identity.token in
  let owner_keeper_identity = caller_identity.owner_keeper_identity in
  let mode_gate_error = caller_identity.mode_gate_error in
  (* Cache resolved agent_name for this session (Fix 4), carrying the
     ephemerality decided from the typed origin so a later call reads it
     back without a substring re-probe. *)
  record_mcp_session_agent ~is_ephemeral:caller_identity.agent_name_is_ephemeral
    agent_name;
  let is_non_public_tool = not (Tool_catalog.is_public_mcp name) in
  let preview ?(max_len = 240) text =
    String_util.utf8_safe ~max_bytes:(max_len + 3) ~suffix:"..." text
    |> String_util.to_string
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
  let runtime_error_result ?(tool_name = name) msg =
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Runtime_failure
      ~start_time:(Tool_timing.start ())
      ~data:(`String msg)
      msg
  in
  let auth_error_result err =
    let message = Masc_domain.masc_error_to_string err in
    let fields =
      [ ( "effect_disposition"
        , `String
            (Tool_result.failure_effect_disposition_to_string
               Tool_result.Proven_pre_effect) )
      ]
      @
      match Masc_domain.dashboard_auth_error_code err with
      | Some code -> [ "auth_error_code", `String code ]
      | None -> []
    in
    Tool_result.make_err
      ~tool_name:name
      ~class_:Tool_result.Policy_rejection
      ~start_time:(Tool_timing.start ())
      ~data:(`Assoc fields)
      message
  in
  let with_non_public_tool_audit ~agent_name (result : Tool_result.result) =
    if is_non_public_tool
    then (
      let success = not (Tool_result.is_failed result) in
      let error_msg =
        if success then None else Some (preview (Tool_result.message result))
      in
      let details =
        `Assoc
          [ "source", `String "mcp_server_eio_execute"
          ; "allow_direct_call", `Bool (Tool_catalog.allow_direct_call name)
          ; "argument_keys", `List argument_keys_json
          ]
      in
      Audit_log.log_non_public_tool_call
        config
        ~agent_id:agent_name
        ~tool_name:name
        ~success
        ~error_msg
        ~details
        ?trace_id:(Otel_spans.current_trace_id ())
        ());
    result
  in
  if not profile_permitted
  then
    with_non_public_tool_audit ~agent_name
      (Tool_result.make_err
         ~tool_name:name
         ~class_:Tool_result.Policy_rejection
         ~effect_disposition:Tool_result.Proven_pre_effect
         ~start_time:(Tool_timing.start ())
         (Printf.sprintf "Tool '%s' is not available on this MCP endpoint." name))
  else
  match mode_gate_error with
  | Some msg -> with_non_public_tool_audit ~agent_name (runtime_error_result msg)
  | None ->
    (* Enforce tool authorization when enabled *)
    let auth_enabled = Auth.is_auth_enabled config.base_path in
    let auth_result =
      if auth_enabled
      then (
        let permission_result =
          match profile with
          | Mcp_server_eio_tool_profile.Operator_remote ->
            Auth.check_permission
              config.base_path
              ~agent_name
              ~token
              ~permission:Masc_domain.CanAdmin
          (* A seat tool asks for CanPlayMachine through the same catalog check
             every other tool uses; the profile already refused anything else. *)
          | Full | Managed_agent | Seat ->
            Auth.authorize_tool
              config.base_path
              ~agent_name
              ~token
              ~tool_name:name
        in
        match permission_result with
        | Ok () -> Ok ()
        | Error err -> Error err)
      else Ok ()
    in
    (match auth_result with
     | Error err ->
       with_non_public_tool_audit
         ~agent_name
         (auth_error_result err)
     | Ok () ->
          (match owner_keeper_identity with
           | Some (keeper_name, keeper_id)
             when agent_name <> "unknown" && workspace_init_cached ->
             (try
                Workspace_task.update_local_agent_state config ~agent_name (fun agent ->
                  let meta =
                    match agent.meta with
                    | Some existing ->
                      { existing with keeper_name = Some keeper_name; keeper_id }
                    | None ->
                      { session_id = ""
                      ; agent_type = agent.agent_type
                      ; pid = None
                      ; hostname = None
                      ; tty = None
                      ; parent_task = None
                      ; keeper_name = Some keeper_name
                      ; keeper_id
                      }
                  in
                  { agent with meta = Some meta })
              with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | exn ->
                Log.Mcp.warn
                  "keeper owner stamp skipped for %s: %s"
                  agent_name
                  (Printexc.to_string exn))
           | Some _ | None -> ());
          (* Every identified caller participates in the same session timeline,
             independent of tool metadata. *)
          if agent_name <> "unknown"
          then (
            let (_ : Session.session) = Session.register registry ~agent_name in
            ());
          (* Log tool call *)
          Log.Mcp.debug "[%s] %s" agent_name name;
          (* Update activity for any tool call *)
          if agent_name <> "unknown"
          then (
            Session.update_activity registry ~agent_name ();
            (* Every identified call follows the same best-effort workspace
               heartbeat path, independent of tool metadata. *)
            if workspace_init_cached
            then (
              try
                let (_ : Workspace.heartbeat_outcome) =
                  Workspace.heartbeat config ~agent_name
                in
                ()
              with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | exn ->
                Log.Misc.warn
                  "heartbeat update skipped for %s on %s: %s"
                  agent_name
                  name
                  (Printexc.to_string exn)));
          (* === Fix 1: Tag-based lazy context dispatch ===
     O(1) tag lookup determines which module handles this tool.
     Only the matched module's context is created (1 out of 45+).
     Eliminates per-call 40+ context creation and ~210 Hashtbl.replace. *)

            (* Helper: create keeper tool boundary context (shared by goals) *)
            let make_keeper_tool_ctx () =
              Keeper_tool_boundary.create
                ?invocation_ref
                ~config
                ~agent_name
                ~sw
                ~clock
                ~proc_mgr:state.Mcp_server.proc_mgr
                ~net:state.Mcp_server.net
                ~publication_recovery_provider:
                  (Mcp_server.publication_recovery_availability_provider state)
                ()
            in
            (* Dispatch a single module by tag — creates only that module's context.
     Pre-hooks may coerce arguments (e.g. AGENT_CORE type coercion: "42" -> 42).
     Returns [Tool_result.result option] directly — no tuple intermediary. *)
            let dispatch_by_tag (tag : Tool_dispatch.module_tag) : Tool_result.result option =
              let start_time = Tool_timing.start () in
              match Tool_dispatch.run_pre_hooks ~schema:None ~name ~args:arguments with
              | Some blocked, _ -> Some blocked
              | None, coerced_args ->
                (match tag with
                 | Mod_plan -> Tool_plan.dispatch { config } ~name ~args:coerced_args
                 | Mod_operator ->
                   let delegated_dispatch =
                     Keeper_tool_boundary.delegated_dispatch
                       ?invocation_ref
                       ~config
                       ~agent_name
                       ~sw
                       ~clock
                       ~proc_mgr:state.Mcp_server.proc_mgr
                       ~net:state.Mcp_server.net
                       ~publication_recovery_provider:
                         (Mcp_server.publication_recovery_availability_provider
                            state)
                       ()
                   in
                   let ctx =
                     { Tool_operator.config
                     ; agent_name
                     ; sw
                     ; clock
                     ; proc_mgr = state.Mcp_server.proc_mgr
                     ; net = state.Mcp_server.net
                     ; delegated_dispatch = Some delegated_dispatch
                     ; mcp_session_id
                     }
                   in
                   Tool_operator.dispatch ctx ~name ~args:coerced_args
                 | Mod_local_runtime ->
                   Tool_local_runtime.dispatch
                     ({ Tool_local_runtime_core.config
                      ; agent_name
                      ; authorize_external_effect = None
                      }
                      : Tool_local_runtime_core.context)
                     ~name
                     ~args:coerced_args
                 | Mod_run ->
                   Tool_run.dispatch
                     { Tool_run.config; agent_name = Some agent_name }
                     ~name
                     ~args:coerced_args
                 | Mod_agent ->
                   Tool_agent.dispatch
                     { Tool_agent.config; agent_name }
                     ~name
                     ~args:coerced_args
                 | Mod_task ->
                   Task.Tool.dispatch
                     { Task.Tool.config; agent_name; sw = Some sw }
                     ~name
                     ~args:coerced_args
                 | Mod_state ->
                   Tool_workspace.dispatch
                     { Tool_workspace.config; agent_name }
                     ~name
                     ~args:coerced_args
                 | Mod_control ->
                   Tool_control.dispatch
                     { Tool_control.config; agent_name }
                     ~name
                     ~args:coerced_args
                 | Mod_agent_timeline ->
                   let caller_is_registered_keeper =
                     Keeper_registry.all ~base_path:config.base_path ()
                     |> List.exists
                          (fun (entry : Keeper_registry.registry_entry) ->
                            String.equal entry.name agent_name)
                   in
                   Tool_agent_timeline.dispatch
                     ~load_chat:(fun ~agent_name:requested_agent_name ->
                       if caller_is_registered_keeper
                       then
                         Keeper_chat_timeline_source.lines_for_self
                           ~base_dir:config.base_path
                           ~caller_keeper_name:agent_name
                           ~agent_name:requested_agent_name
                       else
                         Keeper_chat_timeline_source.lines_for
                           ~base_dir:config.base_path
                           ~keeper_name:requested_agent_name)
                     { Tool_agent_timeline.config; agent_name }
                     ~name
                     ~args:coerced_args
                 (* Keeper-only. The language server belongs to the turn's
                    pool, and this endpoint has no turn to end it. The name is
                    registered and this endpoint cannot run it, so it says that
                    rather than answering "Unknown tool". Measured: an idle server
                    held 12-17 MB and a working one 155 MB, so one started
                    here would sit for the life of the server. *)
                 | Mod_code_query ->
                   Some
                     (Tool_result.error
                        ~failure_class:Tool_result.Workflow_rejection
                        ~tool_name:name
                        ~start_time
                        (Printf.sprintf
                           "tool '%s' is keeper-internal; not available on this MCP endpoint \
                            (a language server belongs to the turn's pool, which this \
                            endpoint does not have)"
                           name))
                 | Mod_schedule ->
                   Tool_schedule.dispatch
                     { Tool_schedule.config
                     ; (* The endpoint's own typed origin decides whether it
                          knows the caller: a name it minted for a session
                          that gave none is no one's across sessions. *)
                       caller =
                         (if caller_identity.agent_name_is_ephemeral
                          then Tool_schedule.Unnamed_caller
                          else Tool_schedule.Named_caller agent_name)
                     ; stamp_keeper_wake_result_delivery =
                         (fun ~payload ->
                            Schedule_payload_projection
                            .set_keeper_wake_result_delivery
                              ~payload
                              ~channel:None)
                     ; admit_keeper_wake_creation =
                         Keeper_schedule_creation_admission.run
                     ; withdraw_queued_keeper_wakes =
                         Keeper_schedule_cancel_withdrawal.run
                     ; result_boundary = Tool_output.Sent_to_client
                     }
                     ~name
                     ~args:coerced_args
                 | Mod_misc ->
                   let lane_access = lane_access_for_caller ~config caller_identity in
                   let candle operation =
                     match owner_keeper_identity with
                     | Some (keeper_name, _) ->
                       Some (Keeper_candle_tools.handle ~operation ~base_path:config.base_path
                         ~keeper_name ~keeper_names:(Play_seat.keeper_names config)
                         ~tool_name:name ~start_time ~args:coerced_args)
                     | None ->
                       Some (Tool_result.make_err ~tool_name:name ~start_time
                         ~class_:Tool_result.Policy_rejection
                         "Candle tools require an authenticated Keeper; a supplied caller name is not a wallet identity") in
                   let dispatch ?dos_admission () =
                     Tool_misc.dispatch ?dos_admission
                       ~browser_principal:(browser_principal_for_caller ~config caller_identity)
                       ~lane_access
                       { Tool_misc.config
                       ; agent_name
                       ; help_schemas = Config.raw_all_tool_schemas
                       }
                       ~name
                       ~args:coerced_args
                   in
                   (* Identity, profile membership and tool authorization have
                      passed above. The controller execution boundary shared
                      by Keeper calls and the play routes comes next. *)
                   let misc_operation = Tool_schemas_misc.misc_operation_of_tool_name name in
                   (match misc_operation, Option.bind misc_operation Keeper_candle_tools.operation_of_misc with
                    | _, Some operation -> candle operation
                    | ((Some (Tool_schemas_misc.Misc_lane_declaration_read) | None), None)
                    | (Some (Tool_schemas_misc.Misc_lane_declaration_save), None)
                    | (Some (Tool_schemas_misc.Misc_lane_updates), None)
                    | (Some (Tool_schemas_misc.Misc_lane_attach), None)
                    | (Some (Tool_schemas_misc.Misc_lane_inspect), None)
                    | (Some (Tool_schemas_misc.Misc_lane_observe), None)
                    | (Some (Tool_schemas_misc.Misc_lane_slice), None)
                    | (Some (Tool_schemas_misc.Misc_lane_detach), None)
                    | (Some (Tool_schemas_misc.Misc_lane_evidence), None)
                    | (Some (Tool_schemas_misc.Misc_lane_act), None)
                    | (Some (Tool_schemas_misc.Misc_lane_action_status), None)
                    | (Some (Tool_schemas_misc.Misc_ask), None)
                    | (Some (Tool_schemas_misc.Misc_ask_status), None)
                    | (Some (Tool_schemas_misc.Misc_ask_withdraw), None)
                    | (Some (Tool_schemas_misc.Misc_config), None)
                    | (Some (Tool_schemas_misc.Misc_dashboard), None)
                    | (Some (Tool_schemas_misc.Misc_gc), None)
                    | (Some (Tool_schemas_misc.Misc_sandbox_volume_gc), None)
                    | (Some (Tool_schemas_misc.Misc_keeper_waiting_inventory), None)
                    | (Some (Tool_schemas_misc.Misc_tool_help), None)
                    | (Some (Tool_schemas_misc.Misc_web_fetch), None)
                    | (Some (Tool_schemas_misc.Misc_web_search), None)
                    | (Some (Tool_schemas_misc.Misc_browser_tabs), None)
                    | (Some (Tool_schemas_misc.Misc_browser_read), None)
                    | (Some (Tool_schemas_misc.Misc_browser_session), None)
                    | (Some (Tool_schemas_misc.Misc_browser_goto), None)
                    | (Some (Tool_schemas_misc.Misc_browser_act), None)
                    | (Some (Tool_schemas_misc.Misc_browser_interact), None)
                    | (Some (Tool_schemas_misc.Misc_msx _), None)
                    | (Some (Tool_schemas_misc.Misc_candle_balance), None)
                    | (Some (Tool_schemas_misc.Misc_candle_catalog), None)
                    | (Some (Tool_schemas_misc.Misc_candle_purchase), None)
                    | (Some (Tool_schemas_misc.Misc_candle_equip), None)
                    | (Some (Tool_schemas_misc.Misc_candle_gift), None)
                    | (Some (Tool_schemas_misc.Misc_dos_load), None)
                    | (Some (Tool_schemas_misc.Misc_dos_meta), None)
                    | (Some (Tool_schemas_misc.Misc_dos_inventory), None)
                    | (Some (Tool_schemas_misc.Misc_dos_eject), None)
                    | (Some (Tool_schemas_misc.Misc_dos_screen), None)
                    | (Some (Tool_schemas_misc.Misc_dos_step), None)
                    | (Some (Tool_schemas_misc.Misc_dos_press), None)
                    | (Some (Tool_schemas_misc.Misc_dos_click), None)
                    | (Some (Tool_schemas_misc.Misc_dos_type), None)
                    | (Some (Tool_schemas_misc.Misc_dos_peek), None)
                    | (Some (Tool_schemas_misc.Misc_play_room), None)
                    | (Some (Tool_schemas_misc.Misc_dos_pass), None)
                    | (Some (Tool_schemas_misc.Misc_dos_save), None)
                    | (Some (Tool_schemas_misc.Misc_dos_restore), None)
                    | (Some (Tool_schemas_misc.Misc_pull_requests), None) ->
                      dispatch ())
                 | Mod_wiki ->
                   Tool_wiki.dispatch
                     { Tool_wiki.base_path = config.base_path; agent_name }
                     ~name
                     ~args:coerced_args
                 | Mod_external ->
                   (* Composition root wires the server boundary to the keeper
                      subsystem: [Mod_external] tools (keeper-management tools)
                      dispatch through [Keeper_tool_boundary] with the
                      per-request context built above. The [Tool_dispatch] tag
                      stays subsystem-agnostic; this is where the concrete
                      handler is bound. *)
                   (match
                      Keeper_tool_boundary.dispatch
                        (make_keeper_tool_ctx ())
                        ~name
                        ~args:coerced_args
                    with
                    | Some result -> Some result
                    | None ->
                      (* This composition root binds [Mod_external] to the
                         keeper subsystem, so a [Mod_external] name the keeper
                         boundary declines is a keeper-internal runtime tool
                         (descriptor-owned executor, e.g. keeper_lane_status,
                         keeper_voice_*, tool_read_file). This endpoint has no
                         executor for it; reporting "Unknown tool (registry
                         inconsistency)" was a lie — the name is registered,
                         the endpoint just cannot run it. *)
                      Some
                        (Tool_result.error
                           ~failure_class:Tool_result.Workflow_rejection
                           ~tool_name:name
                           ~start_time
                           (Printf.sprintf
                              "tool '%s' is keeper-internal; not available on this MCP endpoint"
                              name)))
                 | Mod_keeper_task ->
                   Some
                     (Tool_result.error
                        ~failure_class:Tool_result.Workflow_rejection
                        ~tool_name:name
                        ~start_time
                        (Printf.sprintf
                           "tool '%s' is keeper-internal; not available on this MCP endpoint \
                            (use the keeper in-process task handler)"
                           name))
                 | Mod_inline ->
                   let mcp_runtime_ctx : Mcp_tool_runtime.context =
                     { config
                     ; agent_name
                     ; board_reader =
                         (match Tool_name.Board_name.of_string name with
                          | Some _ -> board_reader_for_caller ~config caller_identity
                          | None -> Masc_board_handlers.Board_access.Anonymous)
                     ; registry
                     ; state
                     ; sw
                     ; clock
                     ; arguments = coerced_args
                     ; mcp_session_id
                     ; (* The MCP runtime surface caches under the
                          already-resolved session identity, so carry the
                          ephemerality decided above. *)
                       record_mcp_session_agent =
                         record_mcp_session_agent
                           ~is_ephemeral:caller_identity.agent_name_is_ephemeral
                     ; wait_for_message =
                         (fun registry ~agent_name ~timeout ->
                           wait_for_message_eio ~clock registry ~agent_name ~timeout)
                     }
                   in
                   Mcp_tool_runtime.dispatch mcp_runtime_ctx ~name)
            in
            (* Primary dispatch: mint token and resolve module tag in a single
               routing snapshot lookup at the I/O boundary (Parse, Don't
               Validate). If mint fails, the tool is truly unknown. *)
            match Tool_dispatch.mint_token_with_tag ~name with
               | Error reason ->
                 with_non_public_tool_audit
                   ~agent_name
                   (runtime_error_result
                      ~tool_name:name
                      (Printf.sprintf "Unknown tool: %s (%s)" name reason))
               | Ok (tag, _token) ->
                 (* RFC-0084 §2.2 (PR-8) — wrap the tag-based dispatch with
                    Tool_telemetry.with_span for 4-tuple emission. *)
                 let dispatch_tag_with_telemetry tag =
                   let result, _outcome =
                     Tool_telemetry.with_span ~force_new_trace_id:true ~surface:"mcp" ~tool_name:name (fun _trace_id_thunk ->
                       let r = dispatch_by_tag tag in
                       (* Keep MCP tools/call on the shared post-dispatch
                          transformer and observer contract. *)
                       let r = Tool_dispatch_emit.finalize_from_handler r in
                       r, Dispatch_outcome.(to_string (of_result_option r)))
                   in
                   result
                 in
                 (match dispatch_tag_with_telemetry tag with
                  | Some result -> with_non_public_tool_audit ~agent_name result
                  | None ->
                    Log.Mcp.warn "registry inconsistency: %s minted but no handler" name;
                    with_non_public_tool_audit
                      ~agent_name
                      (runtime_error_result
                         ~tool_name:name
                         (Printf.sprintf "Unknown tool: %s (registry inconsistency)" name)))))
;;

(* RFC-0182 §3.1 — register Tool_workspace.dispatch with the dependency
   inversion ref so
   [Keeper_tool_in_process_runtime.handle_masc_workspace_with_outcome]
   (compiled early) can dispatch workspace tools without statically importing
   [Tool_workspace] (compiled late). *)
let () =
  Workspace_dispatch_ref.dispatch
  := fun ~config ~agent_name ~name ~args ->
    Tool_workspace.dispatch_for_keeper { config; agent_name } ~name ~args
;;
