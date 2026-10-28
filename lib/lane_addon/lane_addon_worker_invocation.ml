open Lane_addon_types
open Result.Syntax
let run ~invocation ~companion ~authorize ~principal ~name ~arguments ~call =
  let invoke controller =
    (match invocation, controller,companion with
    | Direct,(Some _),_ | Direct,_,Some _ -> Error "private admission requires host-context invocation"
    | Direct, None,None -> call ~name ~arguments
    | Host_context, controller,companion ->
        call ~name:Lane_addon_call_context.tool_name
          ~arguments:(Lane_addon_call_context.to_json_with_controller ~controller ~companion
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
          ~arguments:(Lane_addon_call_context.to_json_with_controller ~controller ~companion:None
            ~tool:Machine_controller_contract.release_tool ~arguments:(`Assoc []) ~principal)
        |> Result.map_error (fun detail -> Lane_addon_call_context.Transport_error detail) in
  let snapshot () =
    let* result = call ~name:Machine_controller_contract.snapshot_tool ~arguments:(`Assoc []) in
    if result.Mcp_protocol.Mcp_types.is_error = Some true then
      Error (match companion with None -> Agent_core.Mcp.text_of_tool_result result
        | Some _ -> "private controller snapshot failed")
    else match result.structured_content with
      | Some (`Assoc [("holder", `Null)]) -> Ok None
      | Some (`Assoc [("holder", `String holder)]) when holder <> "" -> Ok (Some holder)
      | _ -> Error "invalid worker controller snapshot" in
  match authorize with None -> invoke None | Some authorize -> authorize ~release_controller ~snapshot ~invoke
