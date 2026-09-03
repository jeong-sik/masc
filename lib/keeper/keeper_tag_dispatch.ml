(** Keeper_tag_dispatch — Tag-based tool dispatch for keeper context.

    Bridges the gap between keeper's available context (config, agent_name,
    Eio globals) and the module-specific contexts needed by Tool_*.dispatch.

    Handler registry dispatch (Tool_dispatch.dispatch) MUST be tried first
    by the caller — this module is the fallback for tools only in tag_registry.

    See: mcp_server_eio_execute.ml dispatch_by_tag for the MCP server version.
    Issue: #4579 *)

(** Stable string label for Otel_metric_store bucketing — keeps the
    metric [tag] dimension separated from per-tool [name]. *)
let string_of_tag (tag : Tool_dispatch.module_tag) : string =
  match tag with
  | Mod_external -> "external"
  | Mod_keeper_task -> "keeper_task"
  | Mod_library -> "library"
  | Mod_task -> "task"
  | Mod_plan -> "plan"
  | Mod_local_runtime -> "local_runtime"
  | Mod_run -> "run"
  | Mod_agent -> "agent"
  | Mod_state -> "state"
  | Mod_control -> "control"
  | Mod_agent_timeline -> "agent_timeline"
  | Mod_schedule -> "schedule"
  | Mod_spawn -> "spawn"
  | Mod_code_query -> "code_query"
  | Mod_misc -> "misc"
  | Mod_inline -> "inline"
  | Mod_operator -> "operator"
;;

(** Dispatch a tool by its module tag using keeper-available context.

    @param config   Workspace configuration
    @param keeper_name Keeper's stable handle ([meta.name])
    @param agent_name  Keeper's task actor identity ([meta.agent_name])
    @param tag      Module tag from [Tool_dispatch.lookup_tag]
    @param name     Tool name
    @param args     Tool arguments JSON

    Returns [Some result] or [None] if module dispatch
    does not recognize the tool name (should not happen when tag is correct). *)
let dispatch
      ~(config : Workspace.config)
      ~(keeper_name : string)
      ~(agent_name : string)
      ~(tag : Tool_dispatch.module_tag)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  : Tool_result.result option
  =
  let start_time = Time_compat.now () in
  let err msg =
    Tool_result.error
      ~failure_class:Tool_result.Runtime_failure
      ~tool_name:name
      ~start_time
      msg
  in
  (* RFC-0189: separate *deliberate caller-misuse rejections* (wrong
     client, wrong surface, deprecated tool) from *runtime/dispatch
     errors* (Tool_local_runtime non-zero exit, try-catch fallback).
     The [workflow_err] sites below answer caller-misuse: keeper
     used a tool from the wrong surface or context.  [err] uses the
     constructor's explicit [Runtime_failure] fallback where the upstream
     boundary has no typed failure variant; message text remains opaque. *)
  let workflow_err msg =
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
      ~tool_name:name ~start_time msg
  in
  (* Wrap dispatch in try-catch to normalize exceptions into error results.
     Tool_*.dispatch functions may raise on unexpected JSON shapes or
     backend failures. Without this, exceptions escape to the keeper loop
     and may crash the agent turn. *)
  try
    match tag with
    (* ── Tier A: config + agent_name only ──────────────────────── *)
    | Mod_plan -> Tool_plan.dispatch { config } ~name ~args
    | Mod_local_runtime ->
      Tool_local_runtime.dispatch
        ({ Tool_local_runtime_core.config
         ; agent_name
         ; authorize_external_effect = None
         }
         : Tool_local_runtime_core.context)
        ~name
        ~args
    | Mod_run ->
      Tool_run.dispatch { Tool_run.config; agent_name = Some agent_name } ~name ~args
    | Mod_agent -> Tool_agent.dispatch { Tool_agent.config; agent_name } ~name ~args
    | Mod_state ->
      Tool_workspace.dispatch_for_keeper
        { Tool_workspace.config; agent_name }
        ~name
        ~args
    | Mod_control ->
      Tool_control.dispatch { Tool_control.config; agent_name } ~name ~args
    | Mod_agent_timeline ->
      Tool_agent_timeline.dispatch
        ~load_chat:(fun ~agent_name:requested_agent_name ->
          Keeper_chat_timeline_source.lines_for_self
            ~base_dir:config.base_path ~caller_keeper_name:agent_name
            ~agent_name:requested_agent_name)
        { Tool_agent_timeline.config; agent_name } ~name ~args
    (* Routed by the descriptor runtime rather than here: a spawn needs the
       turn's registry and switch together, and those are read where the turn
       bound them. *)
    | Mod_spawn -> None
    (* Routed by the descriptor runtime for the same reason: a code query
       needs the turn's language-server pool, which is read where the turn
       bound it. *)
    | Mod_code_query -> None
    | Mod_schedule ->
      Tool_schedule.dispatch
        { Tool_schedule.config
        ; agent_name
        ; stamp_keeper_wake_result_delivery =
            (fun ~payload ->
               Schedule_payload_projection.set_keeper_wake_result_delivery
                 ~payload
                 ~channel:None)
        ; admit_keeper_wake_creation = Keeper_schedule_creation_admission.run
        }
        ~name
        ~args
    | Mod_misc ->
      Tool_misc.dispatch
        { Tool_misc.config
        ; agent_name
        ; help_schemas = Keeper_tool_descriptor.model_visible_schemas ()
        }
        ~name
        ~args
    | Mod_library -> Tool_library.dispatch { Tool_library.agent_name } ~name ~args
    (* ── Tier B: Eio-dependent ─────────────────────────────────── *)
    | Mod_task ->
      Task.Tool.dispatch_for_keeper
        ~created_by:keeper_name
        { Task.Tool.config; agent_name; sw = Eio_context.get_switch_opt () }
        ~name
        ~args
    | Mod_external ->
      (* [Mod_external] tools are dispatched at the MCP server boundary
         (mcp_server_eio_execute.dispatch_by_tag), which has the per-request
         config/agent_name/Eio resources these handlers need. From within a
         keeper turn that context is unavailable, so reject and direct the
         caller to the MCP client surface. Currently these are the
         keeper-management tools registered by [Keeper_tool_surface]. *)
      Some
        (workflow_err
           (Printf.sprintf "tool '%s' is a keeper management tool (use MCP client)" name))
    | Mod_keeper_task ->
      Some
        (workflow_err
           (Printf.sprintf
              "tool '%s' is a keeper task tool; use the keeper in-process task handler"
              name))
    | Mod_operator ->
      Some
        (workflow_err
           (Printf.sprintf
              "tool '%s' belongs to the removed operator surface; keeper runtime stays \
               on Agent_core.Agent.run"
              name))
    (* ── Tier C: MCP-state-dependent ───────────────────────────── *)
    | Mod_inline ->
      Some
        (workflow_err
           (Printf.sprintf
              "tool '%s' requires MCP session context (not available in keeper)"
              name))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    let exn_type =
      let raw = Printexc.to_string exn in
      match String.index_opt raw '(' with
      | Some i -> String.sub raw 0 i
      | None -> if String.length raw > 80 then String.sub raw 0 80 else raw
    in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string TagDispatchFailures)
      ~labels:[ "tag", string_of_tag tag ]
      ();
    Log.Keeper.warn "tag dispatch exception for %s: %s" name (Printexc.to_string exn);
    Some (err (Printf.sprintf "keeper dispatch error for %s: %s" name exn_type))
;;
