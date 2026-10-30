type phase = Direct_task_resolution | Autonomous_task_resolution | Executable_setup

let phase_name = function
  | Direct_task_resolution -> "direct_task_resolution"
  | Autonomous_task_resolution -> "autonomous_task_resolution"
  | Executable_setup -> "executable_setup"
;;

let with_turn_result ?preview ~config ~keeper_name ~turn_ref ~phase operation =
  Keeper_turn_preview.with_preparation_result ~writer:preview ~turn_ref:(Some turn_ref)
    ~phase:Keeper_turn_preview.Skill_preparation (fun () ->
  Keeper_skill_preparation_observation.capture_result operation ~on_report:(fun report ->
    let context : Keeper_runtime_manifest.turn_context =
      {manifest_keeper_name=keeper_name;manifest_trace_id=Ids.Turn_ref.trace_id turn_ref
      ;manifest_keeper_turn_id=Some (Ids.Turn_ref.absolute_turn turn_ref)} in
    let edge_id = Random_id.uuid_v7 () in
    let clock_refs = `Assoc
        ["edge_id",`String edge_id;"lane",`String "keeper";"source_clock",`String "logical"] in
    let payload = match Keeper_skill_preparation_observation.report_to_json report with
      | `Assoc fields -> `Assoc
          (("phase",`String (phase_name phase))::("turn_ref",Ids.Turn_ref.to_yojson turn_ref)::fields)
      | value -> value in
    Keeper_runtime_manifest.make_for_context context
      ~event:Keeper_runtime_manifest.Skill_preparation_observed
      ~status:(Keeper_skill_preparation_observation.outcome_to_string report.outcome)
      ~decision:(Keeper_runtime_manifest.with_payload_role
          ~payload_role:Keeper_runtime_manifest.Operator_evidence
          (Keeper_runtime_manifest.with_clock_refs ~clock_refs (`Assoc ["skill_preparation",payload]))) ()
    |> Keeper_runtime_manifest.append_best_effort ~site:"skill_preparation_observed" config))
;;
