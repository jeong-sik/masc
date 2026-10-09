open Lane_addon_types
let ( let* ) = Result.bind
let run ~invocation ~authorize ~principal ~name ~arguments ~call =
  let invoke controller =
    (match invocation, controller with
    | Direct, Some _ -> Error "controller admission requires host-context invocation"
    | Direct, None -> call ~name ~arguments
    | Host_context, controller ->
        call ~name:Lane_addon_call_context.tool_name
          ~arguments:(Lane_addon_call_context.to_json_with_controller ~controller
            ~tool:name ~arguments ~principal))
    |> Result.map_error (fun detail -> Lane_addon_call_context.Transport_error detail) in
  let release_controller ~holder ~reason =
    match invocation with
    | Direct -> Error (Lane_addon_call_context.Host_refusal
        (Rejected "controller release requires host-context invocation"))
    | Host_context ->
        let controller = Some {Machine_controller_contract.observed_holder=Some holder;
          release=Some reason;handoff_target=None} in
        call ~name:Machine_controller_contract.release_tool
          ~arguments:(Lane_addon_call_context.to_json_with_controller ~controller
            ~tool:Machine_controller_contract.release_tool ~arguments:(`Assoc []) ~principal)
        |> Result.map_error (fun detail -> Lane_addon_call_context.Transport_error detail) in
  let snapshot () =
    let* result = call ~name:Machine_controller_contract.snapshot_tool ~arguments:(`Assoc []) in
    if result.Mcp_protocol.Mcp_types.is_error = Some true then
      Error (Agent_core.Mcp.text_of_tool_result result)
    else match result.structured_content with
      | Some (`Assoc [("holder", `Null)]) -> Ok None
      | Some (`Assoc [("holder", `String holder)]) when holder <> "" -> Ok (Some holder)
      | _ -> Error "invalid worker controller snapshot" in
  match authorize with None -> invoke None | Some authorize -> authorize ~release_controller ~snapshot ~invoke
