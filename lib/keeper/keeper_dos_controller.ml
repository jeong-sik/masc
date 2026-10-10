(** Keeper removal releases only its holder in the attached DOS worker. *)
let release_retired ~config ~keeper_name ~by =
  let events = Machine_addon_host.dos_event_batch ~author:by in
  let result = Fun.protect ~finally:(fun () -> Machine_addon_events.ready events) (fun () ->
    Machine_addon_host.release_shared_controller ~events ~config ~holder:keeper_name ~by
      ~reason:Machine_controller_contract.Keeper_stopped) in
  Machine_addon_events.drain ();
  match result with
  | Ok None -> Ok ()
  | Ok (Some result) ->
      if result.Mcp_protocol.Mcp_types.is_error = Some true then
        Error (Agent_core.Mcp.text_of_tool_result result)
      else (match result.structured_content with
        | Some (`Assoc [("released", `Bool _)]) -> Ok ()
        | _ -> Error "invalid worker controller-release result")
  | Error (Lane_addon_runtime.Unavailable message | Lane_addon_runtime.Outcome_unknown message
      | Lane_addon_runtime.Host_refusal (Lane_addon_call_context.Rejected message | Unavailable message | Activity_disabled message | Activity_unobserved message)) -> Error message
;;
