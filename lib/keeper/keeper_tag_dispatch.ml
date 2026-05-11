(** Keeper_tag_dispatch — Tag-based tool dispatch for keeper context.

    Bridges the gap between keeper's available context (config, agent_name,
    Eio globals) and the module-specific contexts needed by Tool_*.dispatch.

    Handler registry dispatch (Tool_dispatch.dispatch) MUST be tried first
    by the caller — this module is the fallback for tools only in tag_registry.

    See: mcp_server_eio_execute.ml dispatch_by_tag for the MCP server version.
    Issue: #4579 *)

(** Helper: require Eio.Switch.t, return error if unavailable. *)
let require_sw () =
  match Eio_context.get_switch_opt () with
  | Some sw -> Ok sw
  | None -> Error "requires Eio switch (not available in keeper context)"

(** Helper: require Eio clock, return error if unavailable. *)
let require_clock () =
  match Eio_context.get_clock_opt () with
  | Some clock -> Ok clock
  | None -> Error "requires Eio clock (not available in keeper context)"

(** Helper: get optional proc_mgr via Process_eio fallback. *)
let get_proc_mgr_opt () =
  match Process_eio.get_proc_mgr () with
  | Ok pm -> Some pm
  | Error _ -> None

(** Helper: require Eio net, return error if unavailable. *)
let require_net () =
  match Eio_context.get_net_opt () with
  | Some net -> Ok net
  | None -> Error "requires Eio net (not available in keeper context)"

(** Helper: get optional net. *)
let get_net_opt () = Eio_context.get_net_opt ()

(** Helper: get optional fs. *)
let get_fs_opt () = Fs_compat.get_fs_opt ()

(** Dispatch a tool by its module tag using keeper-available context.

    @param config   Coord configuration
    @param agent_name  Keeper's agent name (meta.name)
    @param tag      Module tag from [Tool_dispatch.lookup_tag]
    @param name     Tool name
    @param args     Tool arguments JSON

    Returns [Some result] or [None] if module dispatch
    does not recognize the tool name (should not happen when tag is correct). *)
let dispatch
    ~(config : Coord.config)
    ~(agent_name : string)
    ~(tag : Tool_dispatch.module_tag)
    ~(name : string)
    ~(args : Yojson.Safe.t)
  : Tool_result.t option =
  let start_time = Time_compat.now () in
  let ok msg = Tool_result.ok ~tool_name:name ~start_time msg in
  let err msg = Tool_result.error ~tool_name:name ~start_time msg in
  (* Wrap dispatch in try-catch to normalize exceptions into error results.
     Tool_*.dispatch functions may raise on unexpected JSON shapes or
     backend failures. Without this, exceptions escape to the keeper loop
     and may crash the agent turn. *)
  try match tag with

  (* ── Tier A: config + agent_name only ──────────────────────── *)

  | Mod_plan ->
      Tool_plan.dispatch { config } ~name ~args
  | Mod_local_runtime ->
      Tool_local_runtime.dispatch { Tool_local_runtime.config; agent_name }
        ~name ~args
      |> Option.map (fun (success, message) ->
        if success then ok message else err message)
  | Mod_worktree ->
      Tool_worktree.dispatch { Tool_worktree.config; agent_name } ~name ~args
  | Mod_code ->
      Tool_code.dispatch { Tool_code.config; agent_name } ~name ~args
  | Mod_code_write ->
      Tool_code_write.dispatch { Tool_code_write.config; agent_name }
        ~name ~args
  | Mod_run ->
      Tool_run.dispatch { Tool_run.config } ~name ~args
  | Mod_agent ->
      Tool_agent.dispatch { Tool_agent.config; agent_name } ~name ~args
  | Mod_room ->
      Tool_coord.dispatch { Tool_coord.config; agent_name } ~name ~args
      |> Option.map (fun (result : Tool_result.t) ->
        if result.success then ok (Tool_result.message result)
        else err (Tool_result.message result))
  | Mod_control ->
      if name = "masc_pause_status" then
        Tool_control.dispatch { Tool_control.config; agent_name } ~name ~args
      else
        Some (err (Printf.sprintf
          "tool '%s' is blocked in keeper context (lifecycle-mutating Mod_control tools are operator-only)" name))
  | Mod_agent_timeline ->
      Tool_agent_timeline.dispatch { Tool_agent_timeline.config; agent_name }
        ~name ~args
  | Mod_misc ->
      Tool_misc.dispatch { Tool_misc.config; agent_name } ~name ~args
  | Mod_suspend ->
      Tool_suspend.dispatch { Tool_suspend.config; caller_agent = Some agent_name }
        ~name ~args
  | Mod_library ->
      Tool_library.dispatch { Tool_library.agent_name } ~name ~args

  (* ── Tier A special: Tool_shard returns Yojson.Safe.t ──────── *)

  | Mod_shard ->
      let (success, json) = Tool_shard.execute name args in
      let message = Yojson.Safe.to_string json in
      Some (if success then ok message else err message)

  (* ── Tier B: Eio-dependent ─────────────────────────────────── *)

  | Mod_task ->
      Tool_task.dispatch
        { Tool_task.config; agent_name;
          sw = Eio_context.get_switch_opt () }
        ~name ~args

  | Mod_keeper ->
      Some (err (Printf.sprintf
        "tool '%s' is a keeper management tool (use MCP client)" name))

  | Mod_operator ->
      Some (err (Printf.sprintf
        "tool '%s' belongs to the removed operator surface; keeper runtime stays on OAS Agent.run" name))

  | Mod_autoresearch ->
      let ctx : Tool_autoresearch.context =
        {
          base_path = config.base_path;
          agent_name = Some agent_name;
          start_operation = None;
          config = Some config;
          sw = Eio_context.get_switch_opt ();
          clock = Eio_context.get_clock_opt ();
        }
      in
      Tool_autoresearch.dispatch ctx ~name ~args

  (* ── Tier C: MCP-state-dependent ───────────────────────────── *)

  | Mod_inline when String.equal name "masc_approval_pending" ->
      let json = Keeper_approval_queue.list_pending_json () in
      Some (ok (Yojson.Safe.to_string json))

  | Mod_inline ->
      Some (err (Printf.sprintf
        "tool '%s' requires MCP session context (not available in keeper)" name))

  (* ── Tier D: Cycle-breaking — modules that back-reference Keeper_exec_* *)

  | Mod_compact ->
      Some (err (Printf.sprintf
        "tool '%s' is an internal context tool (use MCP client)" name))

  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      let exn_type =
        let raw = Printexc.to_string exn in
        match String.index_opt raw '(' with
        | Some i -> String.sub raw 0 i
        | None -> if String.length raw > 80 then String.sub raw 0 80 else raw
      in
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_tag_dispatch_failures
        ~labels:[("tag", name)]
        ();
      Log.Keeper.warn "tag dispatch exception for %s: %s"
        name (Printexc.to_string exn);
      Some (err (Printf.sprintf "keeper dispatch error for %s: %s" name exn_type))
