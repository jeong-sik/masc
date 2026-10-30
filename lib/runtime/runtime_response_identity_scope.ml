let key : Runtime_response_identity.t option Eio.Fiber.key = Eio.Fiber.create_key ()

let current () =
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> None
  | Fs_compat.Eio_fiber -> Option.join (Eio.Fiber.get key)

let source_ordinal ~tool_name ~(response : Agent_core.Types.api_response)
    ~(source_map : Agent_core.Hooks.admitted_tool_source_map) invocation =
  let planned_index = Agent_core.Tool_contract.Invocation.planned_index invocation in
  if planned_index < 0 then None else
  let tool_use_id = Agent_core.Tool_contract.Invocation.tool_use_id invocation in
  let admitted = List.filter_map (function
    | Llm_provider.Types.ToolUse {id;name;_} -> Some (id,name)
    | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _
    | ToolResult _ | Image _ | Document _ | Audio _ -> None) response.content in
  let selected_sources = List.filter (fun (source : Agent_core.Hooks.admitted_tool_use_source) ->
    source.planned_index = planned_index) source_map.admitted_tool_sources in
  match selected_sources, List.nth_opt admitted planned_index with
  | [source], Some (id,name) ->
    let source_ordinal = source.source_tool_use_ordinal in
    let ordinal_unique = List.length (List.filter (fun (other : Agent_core.Hooks.admitted_tool_use_source) ->
      other.source_tool_use_ordinal = source_ordinal) source_map.admitted_tool_sources) = 1 in
    let resolution_matches = match source.name_resolution with
      | Registered_name -> true
      | Recovered_name {tool_call_id;registered_name;provider_name=_} ->
        String.equal tool_call_id tool_use_id && String.equal registered_name tool_name in
    if String.equal id tool_use_id && String.equal name tool_name && ordinal_unique
       && resolution_matches && source_ordinal >= 0 && source_ordinal < source_map.source_tool_use_count
    then Some source_ordinal else None
  | _ -> None

let with_scope ~actor ~runtime_id ~provider_id operation =
  let execution_id = Agent_core.Event_bus.fresh_id () in
  let response = ref None in
  let hook = function
    | Agent_core.Hooks.BeforeTurn _ -> response := None; Agent_core.Hooks.Continue
    | Agent_core.Hooks.AfterTurn { turn; response = observed; tool_source_map } ->
      response := Some (turn, observed, tool_source_map); Agent_core.Hooks.Continue
    | Agent_core.Hooks.BeforeTurnParams _ | Agent_core.Hooks.PreToolUse _
    | Agent_core.Hooks.PostToolUse _ | Agent_core.Hooks.PostToolUseFailure _
    | Agent_core.Hooks.OnStop _ | Agent_core.Hooks.OnError _ | Agent_core.Hooks.OnToolError _ ->
      Agent_core.Hooks.Continue in
  let hooks = { Agent_core.Hooks.empty with before_turn = Some hook; after_turn = Some hook } in
  let wrap_tool (tool : Agent_core.Tool.t) =
    Agent_core.Tool.map_handler (fun handler environment input ->
      let identity = match actor, !response, provider_id, Agent_core.Tool.Execution_env.invocation environment with
        | Some actor, Some (turn, observed, Some source_map), Some provider_id, Some invocation ->
          let tool_use_id = Agent_core.Tool_contract.Invocation.tool_use_id invocation in
          let ordinal = source_ordinal ~tool_name:tool.schema.name ~response:observed ~source_map invocation in
          if turn <> Agent_core.Tool_contract.Invocation.turn invocation then None else
          (match ordinal, Option.bind observed.Agent_core.Types.telemetry
            (fun telemetry -> telemetry.Llm_provider.Types.reported_model) with
           | None, _ | _, None | _, Some Provider_model_not_reported -> None
           | Some source_tool_use_ordinal, Some (Provider_reported_model model_id) ->
             (match Runtime_response_identity.make ~execution_id ~actor ~runtime_id
               ~response_id:observed.id ~provider_id ~model_id
               ~tool_use_id ~provider_turn:turn ~source_tool_use_ordinal with
              | Ok identity -> Some identity
              | Error _ -> None))
        | None, _, _, _ | _, None, _, _ | _, Some (_,_,None), _, _
        | _, _, None, _ | _, _, _, None -> None in
      Eio.Fiber.with_binding key identity (fun () -> handler environment input)) tool in
  (* Mask any parent tool's identity while a nested execution is being built.
     Only an actual invocation of one of its wrapped tools can expose a value. *)
  Eio.Fiber.with_binding key None (fun () -> operation ~hooks ~wrap_tool)

let without_identity operation = match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> operation ()
  | Fs_compat.Eio_fiber -> Eio.Fiber.with_binding key None operation
