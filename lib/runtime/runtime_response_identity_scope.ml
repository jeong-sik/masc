let key : Runtime_response_identity.t option Eio.Fiber.key = Eio.Fiber.create_key ()

let current () =
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> None
  | Fs_compat.Eio_fiber -> Option.join (Eio.Fiber.get key)

let with_scope ~actor ~runtime_id ~provider_id operation =
  let execution_id = Agent_core.Event_bus.fresh_id () in
  let response = ref None in
  let hook = function
    | Agent_core.Hooks.BeforeTurn _ -> response := None; Agent_core.Hooks.Continue
    | Agent_core.Hooks.AfterTurn { turn; response = observed; _ } ->
      response := Some (turn, observed); Agent_core.Hooks.Continue
    | Agent_core.Hooks.BeforeTurnParams _ | Agent_core.Hooks.PreToolUse _
    | Agent_core.Hooks.PostToolUse _ | Agent_core.Hooks.PostToolUseFailure _
    | Agent_core.Hooks.OnStop _ | Agent_core.Hooks.OnError _ | Agent_core.Hooks.OnToolError _ ->
      Agent_core.Hooks.Continue in
  let hooks = { Agent_core.Hooks.empty with before_turn = Some hook; after_turn = Some hook } in
  let wrap_tool (tool : Agent_core.Tool.t) =
    Agent_core.Tool.map_handler (fun handler environment input ->
      let identity = match actor, !response, provider_id, Agent_core.Tool.Execution_env.invocation environment with
        | Some actor, Some (turn, observed), Some provider_id, Some invocation ->
          let tool_use_id = Agent_core.Tool_contract.Invocation.tool_use_id invocation in
          let matching_calls, matching_ids = List.fold_left (fun (calls, ids) -> function
            | Agent_core.Types.ToolUse { id; name; _ } when String.equal id tool_use_id ->
              (if String.equal name tool.schema.name then calls + 1 else calls), ids + 1
            | ToolUse _ | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _
            | ToolResult _ | Image _ | Document _ | Audio _ -> calls, ids) (0, 0) observed.content in
          if turn <> Agent_core.Tool_contract.Invocation.turn invocation
             || matching_calls <> 1 || matching_ids <> 1 then None else
          (match Option.bind observed.Agent_core.Types.telemetry
            (fun telemetry -> telemetry.Llm_provider.Types.reported_model) with
           | None | Some Provider_model_not_reported -> None
           | Some (Provider_reported_model model_id) ->
             (match Runtime_response_identity.make ~execution_id ~actor ~runtime_id
               ~response_id:observed.id ~provider_id ~model_id
               ~tool_use_id ~provider_turn:turn with
              | Ok identity -> Some identity
              | Error _ -> None))
        | None, _, _, _ | _, None, _, _ | _, _, None, _ | _, _, _, None -> None in
      Eio.Fiber.with_binding key identity (fun () -> handler environment input)) tool in
  (* Mask any parent tool's identity while a nested execution is being built.
     Only an actual invocation of one of its wrapped tools can expose a value. *)
  Eio.Fiber.with_binding key None (fun () -> operation ~hooks ~wrap_tool)

let without_identity operation = match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> operation ()
  | Fs_compat.Eio_fiber -> Eio.Fiber.with_binding key None operation
