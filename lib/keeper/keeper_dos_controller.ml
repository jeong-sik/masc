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

type participation_error = Credential_changed | Not_a_seat | Participation_unavailable of string

let set_participation ~config ~who ~token participation =
  let unavailable detail = Participation_unavailable detail in
  let events = Machine_addon_host.dos_event_batch ~author:who in
  let result = Auth.with_credential_transaction config.Workspace.base_path (fun transaction ->
    let ( let* ) = Result.bind in
    let* current = Auth.current_credential_in_transaction transaction who
      |> Result.map_error (fun error -> unavailable (Masc_domain.masc_error_to_string error)) in
    let* credential = match current with
      | Some credential when String.equal credential.Masc_domain.token
          Digestif.SHA256.(digest_string token |> to_hex)
          && Masc_domain.has_permission credential.role Masc_domain.CanPlayMachine ->
        (match Play_invite.expired ~now:(Time_compat.now ()) credential with
         | Ok false -> Ok credential
         | Ok true | Error _ -> Error Credential_changed)
      | Some _ | None -> Error Credential_changed in
    (* Only a seat has a play session. A Worker departure would release its
       Keeper's controller while Play_participation.current never reads it. *)
    let* () = match credential.role with
      | Masc_domain.Worker -> Error Not_a_seat
      | Masc_domain.Admin | Masc_domain.Player -> Ok () in
    (* Do not overwrite an unreadable state with an apparently fresh session. *)
    let* _ = Play_participation.read ~transaction ~base_path:config.base_path credential
      |> Result.map_error unavailable in
    let* () = Play_participation.write ~transaction ~base_path:config.base_path credential participation
      |> Result.map_error unavailable in
    match participation with
    | Connected -> Ok ()
    | Departed ->
      (match Fun.protect ~finally:(fun () -> Machine_addon_events.ready events) (fun () ->
         Machine_addon_host.release_shared_controller ~events ~config ~holder:who ~by:who
           ~reason:Machine_controller_contract.Participant_departed) with
       | Ok None -> Ok ()
       | Ok (Some result) ->
           if result.Mcp_protocol.Mcp_types.is_error = Some true then
             Error (unavailable (Agent_core.Mcp.text_of_tool_result result))
           else (match result.structured_content with
             | Some (`Assoc [("released", `Bool _)]) -> Ok ()
             | _ -> Error (unavailable "invalid worker controller-release result"))
       | Error (Lane_addon_runtime.Unavailable message | Lane_addon_runtime.Outcome_unknown message
           | Lane_addon_runtime.Host_refusal (Lane_addon_call_context.Rejected message | Unavailable message
             | Activity_disabled message | Activity_unobserved message)) -> Error (unavailable message)))
    |> Result.map_error (fun error -> unavailable (Masc_domain.masc_error_to_string error))
    |> Result.join in
  (* Board publication runs after the credential admission, like every other
     controller effect. *)
  Machine_addon_events.drain ();
  result
;;
