(** Keeper_tools_oas — Wrap keeper tools as OAS Tool.t for Agent.run().

    Bridges [Keeper_exec_tools.execute_keeper_tool_call] dispatch
    to [Agent_sdk.Tool.t] list via [Tool_bridge.oas_tool_of_masc].

    Tool execution reads current context from [ctx_ref] (mutable ref),
    enabling Agent.run() to manage messages while keeper tools
    access the working context for status/metrics.

    @since Phase 4 — Keeper → Agent.run() migration *)

(** Build OAS Tool.t list from keeper's allowed tools.

    Each tool delegates to [execute_keeper_tool_call] with the current
    [ctx_ref] snapshot. Tools that raise exceptions return error results
    instead of crashing the agent loop.

    @param config Room configuration for tool dispatch
    @param meta Keeper metadata (determines which tools are allowed)
    @param ctx_ref Mutable ref to current working context *)
let make_tools
    ~(config : Room.config)
    ~(meta : Keeper_types.keeper_meta)
    ~(ctx_ref : Context_manager.working_context ref)
  : Agent_sdk.Tool.t list =
  let allowed_names =
    Keeper_exec_tools.keeper_allowed_tool_names meta
  in
  let tool_defs =
    Keeper_exec_tools.keeper_allowed_llm_tools meta
  in
  List.filter_map (fun (td : Types.tool_schema) ->
    if List.mem td.name allowed_names then
      Some (Tool_bridge.oas_tool_of_masc
        ~name:td.name
        ~description:td.description
        ~input_schema:td.input_schema
        (fun input ->
          try
            let result =
              Keeper_exec_tools.execute_keeper_tool_call
                ~config ~meta ~ctx_work:(!ctx_ref)
                ~name:td.name ~input
            in
            (true, result)
          with exn ->
            let msg = Printf.sprintf "tool %s failed: %s"
              td.name (Printexc.to_string exn) in
            Log.Keeper.error "%s" msg;
            (false, msg)))
    else None
  ) tool_defs
