module Authority = Keeper_machine_controller_authority

let refusal = function
  | Authority.Refused message -> Lane_addon_call_context.Host_refusal (Rejected message)
  | Authority.Seats_unknown message -> Lane_addon_call_context.Host_refusal (Unavailable message)

let pass_target arguments =
  match Tool_args.get_string_opt arguments "to" with
  | None -> Ok None
  | Some target when String.trim target = "" -> Ok None
  | Some target ->
      let normalized = String.trim target in
      match Validation.Id_shape.parse normalized with
      | Ok _ -> Ok (Some normalized)
      | Error _ -> Error (Printf.sprintf
          "to %S is not a Keeper name: give the name alone, without @ or spaces" target)

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
  | Some _ | None -> None

let execution_machine operation arguments =
  match operation with
  | Some (Tool_schemas_misc.Misc_msx_load | Misc_msx_restore | Misc_msx_change_disk
      | Misc_msx_press | Misc_msx_step | Misc_msx_step_until_change) -> Some Machine_lane.Msx
  | Some (Tool_schemas_misc.Misc_dos_load | Misc_dos_restore | Misc_dos_step
      | Misc_dos_press | Misc_dos_click | Misc_dos_type) -> Some Machine_lane.Dos
  | Some Tool_schemas_misc.Misc_dos_pass ->
      (match pass_target arguments with Ok None -> None | Ok (Some _) | Error _ -> Some Machine_lane.Dos)
  | Some _ | None -> None

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

(* The refusal text an attached worker answers with when activity is on but no
   machine is loaded. The [machine] is known not to be running: an attached
   worker would answer from its own lane state, and the shell below answers
   with the same sentence without one. *)
let activity_refusal_message = function
  | Machine_lane.Msx -> "no MSX machine is loaded: call masc_msx_load first"
  | Machine_lane.Dos -> "no DOS machine is loaded: call masc_dos_load first"

(* The typed admission answer a fresh workspace -- no declaration file, so no
   attached worker -- gives a machine-tool call. [Some] carries the same
   sentence the attached worker would have produced; [None] leaves the
   endpoint-level unknown-tool refusal to the caller for names that are not
   machine tools. *)
let shared_admission_refusal ~config ~name =
  let access = Lane_addon_sources.Unauthenticated in
  let reserved = List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
    Config.raw_all_tool_schemas in
  match Lane_addon_runtime.tool_exports ~config ~access ~reserved with
  | Ok exports when List.exists (fun (export : Lane_addon_tool_export.t) ->
      String.equal export.tool.name name) exports -> None
  | _ ->
    let operation = Tool_schemas_misc.misc_operation_of_tool_name name in
    let machine =
      match operation with
      | None -> None
      | Some misc_operation -> execution_machine (Some misc_operation) `Null
    in
    match machine with
    | Some machine -> (
        match require_activity machine with
        | Error (Lane_addon_call_context.Host_refusal refusal) ->
            (match refusal with
             | Lane_addon_call_context.Activity_disabled detail
             | Lane_addon_call_context.Activity_unobserved detail ->
                 Some detail
             | Lane_addon_call_context.Rejected detail
             | Lane_addon_call_context.Unavailable detail ->
                 Some detail)
        | Error (Lane_addon_call_context.Transport_error detail) ->
            Some detail
        | Ok () -> Some (activity_refusal_message machine))
    | None ->
        (* Misc_dos_pass only names its machine when a handoff target is
           present; without one the shell still owes the caller a typed
           no-worker refusal when a declaration exists but this name is not
           exported. *)
        match operation with
        | Some _ -> Some ("No attached shared Add-on provides " ^ name)
        | None -> None

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
  match Lane_addon_runtime.tool_exports ~config ~access ~reserved with
  | Error detail -> Error (Lane_addon_runtime.Unavailable detail)
  | Ok exports ->
      match List.find_opt (fun (export : Lane_addon_tool_export.t) ->
        String.equal export.tool.name name) exports with
      | None ->
          (* No attached worker provides the tool. Before the worker attaches
             (a fresh workspace has no lane-addons declaration yet) the call
             still owes the admission answer the attached worker would give --
             the activity-off or no-machine-loaded sentence -- instead of the
             endpoint-level "tool does not exist" the protocol gate would
             produce from an export miss (#41199 stdio contract,
             docs/guides/machine-activity.md). The shell is typed and
             pre-effect: it starts no machine, container, or emulator. *)
          (match shared_admission_refusal ~config ~name with
           | Some detail -> Error (Lane_addon_runtime.Unavailable detail)
           | None ->
               Error (Lane_addon_runtime.Unavailable
                        ("No attached shared Add-on provides " ^ name)))
      | Some export -> call ~principal ~config ~access ~reserved ~export ~arguments

let release_shared_controller ~events ~config ~holder ~by ~reason =
  let access = Lane_addon_sources.Unauthenticated in
  let reserved = List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
    Config.raw_all_tool_schemas in
  match Lane_addon_runtime.tool_exports ~config ~access ~reserved with
  | Error detail -> Error (Lane_addon_runtime.Unavailable detail)
  | Ok exports ->
      match List.find_opt (fun (export : Lane_addon_tool_export.t) ->
        String.equal export.tool.name "masc_dos_pass") exports with
      | None -> Ok None
      | Some export ->
          let authorize ~release_controller ~snapshot:_ ~invoke:_ = release_controller ~holder ~reason in
          Lane_addon_runtime.call_exported_tool_with_authority ~on_complete:(fun () -> ())
            ~on_result:(Machine_addon_events.record events)
            ~authorize:(Some authorize)
            ~principal:(Some (Lane_addon_call_context.Host_actor by))
            ~config ~access ~reserved ~export ~arguments:(`Assoc [])
          |> Result.map Option.some
