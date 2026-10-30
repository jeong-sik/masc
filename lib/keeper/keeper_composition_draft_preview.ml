module Plan = Keeper_tool_plan

let preview draft =
  let batches = Keeper_tool_plan_executor.schedule (Keeper_composition_draft.plan draft) |> List.map (function
    | Keeper_tool_plan_executor.Serial_batch node ->
      `List [ `Assoc [ "node_id", `String (Plan.Node_id.to_string node.node.id)
                      ; "schedule", Keeper_tool_composition_projection.schedule_to_json node.schedule ] ]
    | Keeper_tool_plan_executor.Concurrent_batch nodes ->
      `List (List.map (fun (node : Keeper_tool_plan_executor.scheduled_node) ->
        `Assoc [ "node_id", `String (Plan.Node_id.to_string node.node.id)
               ; "schedule", Keeper_tool_composition_projection.schedule_to_json node.schedule ]) nodes)) in
  match Keeper_composition_draft.preview draft with
  | `Assoc fields -> `Assoc (fields @ [ "schedule_preview", `List batches ])
  | _ -> invalid_arg "immutable draft preview must be an object"
;;
