module Authority = Keeper_machine_controller_authority

let refusal = function
  | Authority.Refused message -> Lane_addon_call_context.Host_refusal (Rejected message)
  | Authority.Seats_unknown message -> Lane_addon_call_context.Host_refusal (Unavailable message)

let pass_target arguments =
  Machine_controller_contract.pass_target arguments
    ~parse:(fun name -> Validation.Id_shape.parse name |> Result.map (fun _ -> name))

let mediation ~config ~principal ~arguments ~handoff ~release_controller:_ ~snapshot ~invoke =
  match principal with
  | Lane_addon_call_context.Operator | Anonymous ->
      Error (refusal (Authority.Refused "DOS controller calls require a verified named host principal"))
  | Keeper who | Authenticated_agent who | Host_actor who ->
      let admitted = Auth.with_credential_transaction config.Workspace.base_path (fun transaction ->
        let target = if handoff then pass_target arguments else Ok None in
        let admission = Authority.participation_refusal ~transaction ~config ~who in
        let refused = if handoff then Authority.pass_refusal ~transaction ~config ~target else None in
        match admission, refused with
        | Some reason, _ | None, Some reason -> Error (refusal reason)
        | None, None ->
            match snapshot () with
            | Error detail -> Error (refusal (Authority.Seats_unknown detail))
            | Ok observed_holder ->
                let release = match observed_holder with
                  | Some holder when not (String.equal holder who) ->
                      Authority.holder_left ~transaction ~config ~now:(Time_compat.now ()) holder
                  | Some _ | None -> None in
                match target with
                | Error message -> Error (refusal (Authority.Refused message))
                | Ok handoff_target ->
                    invoke (Some {Machine_controller_contract.observed_holder;release;handoff_target})) in
      match admitted with
      | Ok result -> result
      | Error error -> Error (refusal
          (Authority.Seats_unknown (Masc_domain.masc_error_to_string error)))

let dos_event_batch ~author = Machine_addon_events.create ~author ~relay:Machine_dos_host_events.relay

let event_batch ~principal ~name =
  let author = match principal with
    | Lane_addon_call_context.Keeper name | Authenticated_agent name | Host_actor name -> name
    | Operator | Anonymous -> Lane_addon_call_context.actor_label principal in
  match Option.map Lane_addon_sources.activity_of_misc_operation
      (Tool_schemas_misc.misc_operation_of_tool_name name) with
  | Some (Lane_addon_sources.Machine_changed Machine_lane.Dos) -> Some (dos_event_batch ~author)
  | Some (Lane_addon_sources.Machine_changed Machine_lane.Msx) ->
      Some (Machine_addon_events.create ~author ~relay:Machine_msx_host_events.relay)
  | Some (Lane_addon_sources.Tool_completed) | None | Some (Lane_addon_sources.Browser_changed)
  | Some (Lane_addon_sources.Fusion_changed _) -> None

let execution_machine operation arguments =
  match operation with
  | Some (Tool_schemas_misc.Misc_msx tool) ->
      (match tool with
       | Msx_tool.(Load | Restore | Change_disk | Press | Step | Step_until_change) ->
           Some Machine_lane.Msx
       | Msx_tool.(Eject | Export_disk | Save | Screen | Meta | Checkpoint_info | Peek | Ram_diff) ->
           None)
  | Some (Tool_schemas_misc.Misc_dos_load | Misc_dos_restore | Misc_dos_step
      | Misc_dos_press | Misc_dos_click | Misc_dos_type) -> Some Machine_lane.Dos
  | Some Tool_schemas_misc.Misc_dos_pass ->
      (match pass_target arguments with Ok None -> None | Ok (Some _) | Error _ -> Some Machine_lane.Dos)
  | Some (Tool_schemas_misc.Misc_lane_declaration_read) | None
  | Some (Tool_schemas_misc.Misc_lane_declaration_save) | Some (Tool_schemas_misc.Misc_lane_updates)
  | Some (Tool_schemas_misc.Misc_lane_attach) | Some (Tool_schemas_misc.Misc_lane_inspect)
  | Some (Tool_schemas_misc.Misc_lane_observe) | Some (Tool_schemas_misc.Misc_lane_slice)
  | Some (Tool_schemas_misc.Misc_lane_detach) | Some (Tool_schemas_misc.Misc_lane_evidence)
  | Some (Tool_schemas_misc.Misc_lane_act) | Some (Tool_schemas_misc.Misc_lane_action_status)
  | Some (Tool_schemas_misc.Misc_ask) | Some (Tool_schemas_misc.Misc_ask_status)
  | Some (Tool_schemas_misc.Misc_ask_withdraw) | Some (Tool_schemas_misc.Misc_config)
  | Some (Tool_schemas_misc.Misc_dashboard) | Some (Tool_schemas_misc.Misc_gc)
  | Some (Tool_schemas_misc.Misc_keeper_waiting_inventory) | Some (Tool_schemas_misc.Misc_tool_help)
  | Some (Tool_schemas_misc.Misc_web_fetch) | Some (Tool_schemas_misc.Misc_web_search)
  | Some (Tool_schemas_misc.Misc_browser_tabs) | Some (Tool_schemas_misc.Misc_browser_read)
  | Some (Tool_schemas_misc.Misc_browser_session) | Some (Tool_schemas_misc.Misc_browser_goto)
  | Some (Tool_schemas_misc.Misc_browser_act) | Some (Tool_schemas_misc.Misc_browser_interact)
  | Some (Tool_schemas_misc.Misc_browser_instruct) | Some (Tool_schemas_misc.Misc_portrait_read)
  | Some (Tool_schemas_misc.Misc_candle_balance) | Some (Tool_schemas_misc.Misc_candle_catalog)
  | Some (Tool_schemas_misc.Misc_candle_purchase) | Some (Tool_schemas_misc.Misc_candle_equip)
  | Some (Tool_schemas_misc.Misc_candle_gift) | Some (Tool_schemas_misc.Misc_dos_meta)
  | Some (Tool_schemas_misc.Misc_dos_inventory) | Some (Tool_schemas_misc.Misc_dos_eject)
  | Some (Tool_schemas_misc.Misc_dos_screen) | Some (Tool_schemas_misc.Misc_dos_peek)
  | Some (Tool_schemas_misc.Misc_play_room) | Some (Tool_schemas_misc.Misc_dos_save) -> None

let require_activity machine =
  match Runtime.machine_configuration () with
  | None -> Error (Lane_addon_call_context.Host_refusal (Activity_unobserved "Machine activity configuration is unavailable"))
  | Some configuration ->
      let enabled = match machine with
        | Machine_lane.Msx -> configuration.Machine_configuration.msx_enabled
        | Machine_lane.Dos -> configuration.Machine_configuration.dos_enabled in
      if enabled then Ok ()
      else Error (Lane_addon_call_context.Host_refusal (Activity_disabled
        ("machines." ^ Machine_lane.to_wire machine ^ " is off; enable it before new machine work")))

let call ~principal ~config ~access ~reserved ~(export : Lane_addon_tool_export.t) ~arguments =
  let name = export.tool.name in
  let operation = Tool_schemas_misc.misc_operation_of_tool_name name in
  let authorize = match operation with
    | Some operation ->
        (match Tool_schemas_misc.dos_controller_need operation with
         | Takes_controller -> Some (mediation ~config ~principal ~arguments ~handoff:false)
         | Hands_controller -> Some (mediation ~config ~principal ~arguments ~handoff:true)
         | No_controller -> None)
    | None -> None in
  let authorize = match execution_machine operation arguments with
    | None -> authorize
    | Some machine -> Some (fun ~release_controller ~snapshot ~invoke ->
        let guarded controller = Result.bind (require_activity machine) (fun () -> invoke controller) in
        match authorize with
        | None -> guarded None
        | Some authorize -> authorize ~release_controller ~snapshot ~invoke:guarded) in
  let events = event_batch ~principal ~name in
  let on_result result = Option.iter (fun batch -> Machine_addon_events.record batch result) events in
  let on_complete () = Option.iter Machine_addon_events.ready events in
  let result = Lane_addon_runtime.call_exported_tool_with_authority ~on_complete ~on_result ~authorize
    ~principal:(Some principal) ~config ~access ~reserved ~export ~arguments in
  Machine_addon_events.drain ();
  result

let call_shared ~principal ~config ~name ~arguments =
  let access = Lane_addon_sources.Unauthenticated in
  let reserved = List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
    Config.raw_all_tool_schemas in
  match Lane_addon_runtime.tool_export_reading ~config ~access ~reserved with
  | Error detail -> Error (Lane_addon_runtime.Unavailable detail)
  | Ok reading ->
      match List.find_opt (fun (export : Lane_addon_tool_export.t) ->
        String.equal export.tool.name name) reading.exports with
      | None -> Error (Lane_addon_runtime.Unavailable
          (match Lane_addon_unready.summary (Lane_addon_unready.declaring ~name reading.unready) with
           | Some reason -> reason
           | None -> "No attached shared Add-on provides " ^ name))
      | Some export -> call ~principal ~config ~access ~reserved ~export ~arguments

let release_shared_controller ~events ~config ~holder ~by ~reason =
  let access = Lane_addon_sources.Unauthenticated in
  let reserved = List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
    Config.raw_all_tool_schemas in
  let name = Machine_controller_contract.(dos_tool_name Dos_pass) in
  match Lane_addon_runtime.tool_export_reading ~config ~access ~reserved with
  | Error detail -> Error (Lane_addon_runtime.Unavailable detail)
  | Ok reading ->
      match List.find_opt (fun (export : Lane_addon_tool_export.t) ->
        String.equal export.tool.name name) reading.exports with
      | None ->
          (* An installation that declares the controller but cannot serve may
             still hold it in its state, so nothing was released. *)
          (match Lane_addon_unready.summary (Lane_addon_unready.declaring ~name reading.unready) with
           | Some reason -> Error (Lane_addon_runtime.Unavailable reason)
           | None -> Ok None)
      | Some export ->
          let authorize ~release_controller ~snapshot:_ ~invoke:_ = release_controller ~holder ~reason in
          Lane_addon_runtime.call_exported_tool_with_authority ~on_complete:(fun () -> ())
            ~on_result:(Machine_addon_events.record events)
            ~authorize:(Some authorize)
            ~principal:(Some (Lane_addon_call_context.Host_actor by))
            ~config ~access ~reserved ~export ~arguments:(`Assoc [])
          |> Result.map Option.some
