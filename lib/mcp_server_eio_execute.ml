(** Mcp_server_eio_execute — Core execute_tool_eio dispatcher

    Extracted from mcp_server_eio.ml.
    Contains the main tool dispatch function that resolves agent identity,
    checks authorization, session-binds, and delegates to tool modules.
*)

let log_mcp_exn = Mcp_server_eio_helpers.log_mcp_exn
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

let cleanup_internal_keeper_runtime_resource ~during_exception ~label cleanup =
  try cleanup () with
  | Eio.Cancel.Cancelled _ as e when not during_exception -> raise e
  | exn ->
    Log.Mcp.warn
      "internal keeper runtime %s cleanup failed%s: %s"
      label
      (if during_exception then " while preserving primary exception" else "")
      (Printexc.to_string exn)
;;

let run_with_cleanup_preserving_primary ~cleanup f =
  match f () with
  | result ->
    cleanup ~during_exception:false ();
    result
  | exception exn ->
    let bt = Printexc.get_raw_backtrace () in
    cleanup ~during_exception:true ();
    Printexc.raise_with_backtrace exn bt
;;

module For_testing = struct
  let cleanup_internal_keeper_runtime_resource = cleanup_internal_keeper_runtime_resource
  let run_with_cleanup_preserving_primary = run_with_cleanup_preserving_primary
end

let execute_tool_eio
      ~sw
      ~clock
      ?(profile = Mcp_server_eio_tool_profile.Full)
      ?mcp_session_id
      ?auth_token
      ?(internal_keeper_runtime = false)
      state
      ~name
      ~arguments
  =
  (* clock parameter used for Session_eio.wait_for_message *)
  (* mcp_session_id: HTTP MCP session ID for in-process identity continuity. *)
  (* Defensive: refresh Eio global context for downstream helpers that still
     consult the ambient switch/clock during a request. Tests may leave a
     finished switch in the global slot between runs, so keep it aligned with
     the current request scope. *)
  Eio_context.set_switch sw;
  Eio_context.set_clock clock;
  (* Otel_metric_store: count every inbound tool call *)
  Otel_metric_store.record_request ();
  let config = (Mcp_server.workspace_config state) in
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
  let caller_identity =
    Mcp_server_eio_caller_identity.resolve ~config ~tool_name:name ~arguments
      ~identity ~cached_resolved_agent ~auth_token ~internal_keeper_runtime
      ~workspace_initialized:(fun () -> workspace_init_cached)
      ~log_mcp_exn
  in
  let agent_name = caller_identity.agent_name in
  let token = caller_identity.token in
  let internal_keeper_runtime_tool =
    caller_identity.internal_keeper_runtime_tool
  in
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
      ~start_time:(Time_compat.now ())
      ~data:(`String msg)
      msg
  in
  let with_non_public_tool_audit ~agent_name (result : Tool_result.result) =
    if is_non_public_tool
    then (
      let error_msg =
        if Tool_result.is_success result then None else Some (preview (Tool_result.message result))
      in
      let details =
        `Assoc
          [ "source", `String "mcp_server_eio_execute"
          ; "visible_in_tools_list", `Bool (Tool_catalog.is_visible name)
          ; "allow_direct_call", `Bool (Tool_catalog.allow_direct_call name)
          ; "mcp_session_id_present", `Bool (Option.is_some mcp_session_id)
          ; "argument_keys", `List argument_keys_json
          ]
      in
      Audit_log.log_non_public_tool_call
        config
        ~agent_id:agent_name
        ~tool_name:name
        ~success:(Tool_result.is_success result)
        ~error_msg
        ~details
        ?trace_id:(Otel_spans.current_trace_id ())
        ());
    result
  in
  match mode_gate_error with
  | Some msg -> with_non_public_tool_audit ~agent_name (runtime_error_result msg)
  | None ->
    (* Enforce tool authorization when enabled *)
    let auth_enabled = Auth.is_auth_enabled config.base_path in
    let auth_result =
      if auth_enabled
      then (
        match
          Auth.authorize_tool_v2 config.base_path ~agent_name ~token ~tool_name:name
        with
        | Ok () -> Ok ()
        | Error err -> Error err)
      else Ok ()
    in
    (match auth_result with
     | Error err ->
       with_non_public_tool_audit
         ~agent_name
         (runtime_error_result (Masc_domain.masc_error_to_string err))
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
                let (_ : string) = Workspace.heartbeat config ~agent_name in
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
                ~config
                ~agent_name
                ~sw
                ~clock
                ~proc_mgr:state.Mcp_server.proc_mgr
                ~net:state.Mcp_server.net
            in
            (* Dispatch a single module by tag — creates only that module's context.
     Pre-hooks may coerce arguments (e.g. OAS type coercion: "42" -> 42).
     Returns [Tool_result.result option] directly — no tuple intermediary. *)
            let dispatch_by_tag (tag : Tool_dispatch.module_tag) : Tool_result.result option =
              let start_time = Time_compat.now () in
              match Tool_dispatch.run_pre_hooks ~name ~args:arguments with
              | Some blocked, _ -> Some blocked
              | None, coerced_args ->
                (match tag with
                 | Mod_plan -> Tool_plan.dispatch { config } ~name ~args:coerced_args
                 | Mod_operator ->
                   let ctx =
                     { Tool_operator.config
                     ; agent_name
                     ; sw
                     ; clock
                     ; proc_mgr = state.Mcp_server.proc_mgr
                     ; net = state.Mcp_server.net
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
                 (* Mod_handover, Mod_heartbeat, Mod_auth removed: tools pruned *)
                 | Mod_compact -> None
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
                   Tool_agent_timeline.dispatch
                     ~load_chat:(fun ~agent_name:requested_agent_name ->
                       if
                         Keeper_identity.is_keeper_principal_agent_name agent_name
                         || Option.is_some
                              (Keeper_registry_lookup.find_by_name agent_name)
                         || Option.is_some
                              (Keeper_registry_lookup.find_by_agent_name
                                 agent_name)
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
                 | Mod_schedule ->
                   Tool_schedule.dispatch
                     { Tool_schedule.config; agent_name }
                     ~name
                     ~args:coerced_args
                 | Mod_misc ->
                   Tool_misc.dispatch
                     { Tool_misc.config; agent_name }
                     ~name
                     ~args:coerced_args
                 | Mod_library ->
                   Tool_library.dispatch
                     { Tool_library.agent_name }
                     ~name
                     ~args:coerced_args
                 | Mod_recurring ->
                   Keeper_recurring_tool.dispatch ~agent_name ~name ~args:coerced_args
                 | Mod_external ->
                   (* Composition root wires the server boundary to the keeper
                      subsystem: [Mod_external] tools (keeper-management tools)
                      dispatch through [Keeper_tool_boundary] with the
                      per-request context built above. The [Tool_dispatch] tag
                      stays subsystem-agnostic; this is where the concrete
                      handler is bound. *)
                   Keeper_tool_boundary.dispatch
                     (make_keeper_tool_ctx ())
                     ~name
                     ~args:coerced_args
                 | Mod_keeper_task ->
                   Some
                     (Tool_result.error
                        ~failure_class:(Some Tool_result.Workflow_rejection)
                        ~tool_name:name
                        ~start_time
                        (Printf.sprintf
                           "tool '%s' is a keeper task tool; use the keeper in-process task handler"
                           name))
                 | Mod_inline ->
                   let mcp_runtime_ctx : Mcp_tool_runtime.context =
                     { config
                     ; agent_name
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
                     ; load_mcp_sessions = Mcp_session_store.load_mcp_sessions
                     ; save_mcp_sessions = Mcp_session_store.save_mcp_sessions
                     }
                   in
                   Mcp_tool_runtime.dispatch mcp_runtime_ctx ~name)
            in
            (* #9784: enrich Unknown tool errors with closest-name suggestions so the
     LLM can self-correct on the next turn rather than re-emit the same
     hallucinated name. Suggestions come from a similarity scan of the
     full tool registry, filtered through Keeper_tool_visibility_projection to
     exclude internal handler names (#17023). *)
            let format_unknown_tool_error ~reason =
              let suggestions =
                Tool_dispatch.find_similar_names ~query:name ()
                |> Keeper_tool_visibility_projection.filter_schema_visible_suggestions
              in
              match suggestions with
              | [] -> Printf.sprintf "Unknown tool: %s (%s)" name reason
              | xs ->
                Printf.sprintf
                  "Unknown tool: %s — did you mean: %s? (%s)"
                  name
                  (String.concat ", " xs)
                  reason
            in
            let internal_keeper_meta_of_agent () =
              match Keeper_registry_lookup.find_by_agent_name agent_name with
              | Some (entry : Keeper_registry.registry_entry)
                when String.equal entry.base_path config.base_path -> Ok entry.meta
              | Some _ | None ->
                let candidates =
                  [ Keeper_identity.canonical_keeper_name_from_agent_name agent_name
                  ; Keeper_identity.canonical_keeper_name agent_name
                  ]
                  |> List.filter_map (function
                    | Some value when String.trim value <> "" -> Some (String.trim value)
                    | _ -> None)
                  |> List.sort_uniq String.compare
                in
                let rec loop = function
                  | [] ->
                    Error
                      (Printf.sprintf
                         "Internal keeper runtime request is not bound to a known keeper \
                          agent: %s"
                         agent_name)
                  | candidate :: rest ->
                    (match Keeper_meta_store.read_meta_resolved config candidate with
                     | Ok (Some (_resolved_name, meta)) -> Ok meta
                     | Ok None -> loop rest
                     | Error msg -> Error msg)
                in
                loop candidates
            in
            let dispatch_internal_keeper_runtime_tool () =
              let start_time = Time_compat.now () in
              match Tool_dispatch.run_pre_hooks ~name ~args:arguments with
              | Some blocked, _ -> Some blocked
              | None, coerced_args ->
                (match internal_keeper_meta_of_agent () with
                 | Error msg ->
                   (* RFC-0189: agent_name has no matching registered
                      keeper (or base_path mismatch).  Caller can
                      address by registering the keeper / fixing the
                      agent invocation context.  Same semantic family
                      as tool_task_handlers' "Agent '%s' is not a
                      member of this workspace" — [Workflow_rejection]. *)
                   Some
                     (Tool_result.error
                        ~failure_class:(Some Tool_result.Workflow_rejection)
                        ~tool_name:name ~start_time msg)
                 | Ok meta ->
                   let ctx_work =
                     Keeper_context_runtime.create
                       ~eio:true
                       ~system_prompt:""
                       ~max_tokens:(Keeper_config.keeper_unified_max_tokens ())
                   in
                               let turn_sandbox_factory =
                                 Some (Keeper_sandbox_factory.create ~config ~meta ())
                               in
                               let cleanup_one ~during_exception label = function
                                 | None -> ()
                     | Some factory ->
                       cleanup_internal_keeper_runtime_resource
                         ~during_exception
                         ~label
                         (fun () -> Keeper_sandbox_factory.cleanup factory)
                               in
                               let cleanup ~during_exception () =
                                 cleanup_one ~during_exception "sandbox" turn_sandbox_factory
                               in
                   let exec_cache = Some (Masc_exec.Exec_cache.create ()) in
                   let result =
                     run_with_cleanup_preserving_primary ~cleanup (fun () ->
                       Keeper_tool_dispatch_runtime.execute_keeper_tool_call_with_outcome
                         ~config
                         ~meta
                                     ~ctx_work
                                     ?turn_sandbox_factory
                                     ~exec_cache
                         (* RFC-0182 Phase 5 PR-A.2: thread Eio
                            resources from execute_tool_eio scope. *)
                         ~sw
                         ~clock
                         ?mcp_session_id
                         ~name
                         ~input:coerced_args
                         ())
                   in
                   Some
                     (match result.Keeper_tool_dispatch_runtime.outcome with
                      | `Success ->
                        Tool_result.make_ok
                          ~tool_name:name
                          ~start_time
                          ~data:
                            (Option.value
                               ~default:(`String result.raw_output)
                               result.data)
                          ()
                      | `Failure failure_class ->
                        Tool_result.make_err
                          ~tool_name:name
                          ~class_:failure_class
                          ~start_time
                          ~data:
                            (Option.value
                               ~default:(`String result.raw_output)
                               result.data)
                          result.raw_output))
            in
            (* Primary dispatch: mint token at I/O boundary, then O(1) tag lookup.
     Tool_token validates the name exists in the tag registry (Parse, Don't
     Validate). If mint fails, the tool is truly unknown. *)
            (* RFC-0084 §1.1 + §2.2 (PR-8) — MCP server tag/internal-keeper
               dispatch paths wrap their existing run_pre_hooks + handler
               chains with Tool_telemetry.with_span so every MCP-originated
               tool call emits the telemetry 4-tuple (Span / Metric /
               trace_id; audit slot via [with_non_public_tool_audit] below).
               This brings MCP-originated calls to behavioural parity with
               the keeper turn migration in PR-7. *)
            let dispatch_internal_with_telemetry () =
              let result, _outcome =
                Tool_telemetry.with_span ~force_new_trace_id:true ~surface:"mcp" ~tool_name:name (fun _trace_id_thunk ->
                  let r = dispatch_internal_keeper_runtime_tool () in
                  (* Route through the shared dispatch finalizer so MCP
                     internal-keeper-runtime calls run the same result
                     transformer and dispatch observers as keeper turn calls. *)
                  let r = Tool_dispatch_emit.finalize_from_handler r in
                  let outcome =
                    match r with
                    | Some _ -> "handled"
                    | None -> "no_handler"
                  in
                  r, outcome)
              in
              result
            in
            match
              if internal_keeper_runtime_tool
              then dispatch_internal_with_telemetry ()
              else None
            with
            | Some result -> with_non_public_tool_audit ~agent_name result
            | None ->
              (match Tool_dispatch.mint_token ~name with
               | Error reason ->
                 with_non_public_tool_audit
                   ~agent_name
                   (runtime_error_result
                      ~tool_name:name
                      (format_unknown_tool_error ~reason))
               | Ok _token ->
                 (* Token proves the name is registered in at least one registry.
         lookup_tag None after mint is a registry inconsistency (tool in
         handler registry but not tag registry), not a user error. *)
                 (* RFC-0084 §2.2 (PR-8) — wrap the tag-based dispatch with
                    Tool_telemetry.with_span for 4-tuple emission. *)
                 let dispatch_tag_with_telemetry tag =
                   let result, _outcome =
                     Tool_telemetry.with_span ~force_new_trace_id:true ~surface:"mcp" ~tool_name:name (fun _trace_id_thunk ->
                       let r = dispatch_by_tag tag in
                       (* Keep external MCP tools/call on the same
                          post-dispatch contract as internal keeper calls. *)
                       let r = Tool_dispatch_emit.finalize_from_handler r in
                       let outcome =
                         match r with
                         | Some _ -> "handled"
                         | None -> "no_handler"
                       in
                       r, outcome)
                   in
                   result
                 in
                 let tag_result =
                   match Tool_dispatch.lookup_tag name with
                   | Some tag -> dispatch_tag_with_telemetry tag
                   | None -> None
                 in
                 (match tag_result with
                  | Some result -> with_non_public_tool_audit ~agent_name result
                  | None ->
                    Log.Mcp.warn "registry inconsistency: %s minted but no tag" name;
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
