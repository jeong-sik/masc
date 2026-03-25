open Masc_mcp
open Test_command_plane_v2_support

let test_intent_forecast_blocks_on_active_cross_intent_dependency () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let alpha_lead = "alpha-lead-node" in
      let alpha_two = "alpha-two-node" in
      with_eio_test base_dir @@ fun config ->
      setup_company_and_platoon config ~owner ~alpha_lead ~alpha_two;
      let shared_upstream =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String "Shared setup still running");
              ("workload_profile", `String "coding_task");
              ("stage", `String "implement");
            ])
      in
      let intent =
        unwrap_ok
          (Command_plane_v2.create_intent_json config ~actor:"owner"
             (`Assoc
               [
                 ("title", `String "Cross intent dependency blocks verify");
                 ("artifact_priors", `List [ `String "lib/command_plane_v2.ml" ]);
               ]))
      in
      ignore
        (start_operation_exn config ~actor:"owner"
           (`Assoc
             [
               ("assigned_unit_id", `String "company-main");
               ("objective", `String "Verify after shared setup");
               ("intent_id", `String intent.intent_id);
               ("workload_profile", `String "coding_task");
               ("stage", `String "verify");
               ("depends_on_operation_ids", `List [ `String shared_upstream.operation_id ]);
             ]));
      let forecast =
        unwrap_ok
          (Command_plane_v2.intent_forecast_json config intent.intent_id ())
      in
      Alcotest.(check (list string))
        "blocked_by includes active upstream outside intent"
        [ shared_upstream.operation_id ]
        (forecast |> Yojson.Safe.Util.member "blocked_by"
       |> Yojson.Safe.Util.to_list |> List.map Yojson.Safe.Util.to_string);
      Alcotest.(check bool) "verification gap risk is raised" true
        (forecast |> Yojson.Safe.Util.member "risk_flags"
       |> Yojson.Safe.Util.to_list
       |> List.exists (fun value ->
              String.equal (Yojson.Safe.Util.to_string value) "verification_gap")))

let test_intent_forecast_accepts_checkpointed_cross_intent_dependency () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let alpha_lead = "alpha-lead-node" in
      let alpha_two = "alpha-two-node" in
      with_eio_test base_dir @@ fun config ->
      setup_company_and_platoon config ~owner ~alpha_lead ~alpha_two;
      let shared_upstream =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String "Shared setup checkpointed");
              ("workload_profile", `String "coding_task");
              ("stage", `String "implement");
            ])
      in
      ignore
        (unwrap_ok
           (Command_plane_v2.checkpoint_operation config ~actor:"owner"
              (`Assoc
                [
                  ("operation_id", `String shared_upstream.operation_id);
                  ("checkpoint_ref", `String "shared-upstream-checkpoint");
                ])));
      let intent =
        unwrap_ok
          (Command_plane_v2.create_intent_json config ~actor:"owner"
             (`Assoc
               [
                 ("title", `String "Checkpointed dependency forecast");
                 ("artifact_priors", `List [ `String "lib/command_plane_v2.ml" ]);
               ]))
      in
      ignore
        (start_operation_exn config ~actor:"owner"
           (`Assoc
             [
               ("assigned_unit_id", `String "company-main");
               ("objective", `String "Verify after shared checkpoint");
               ("intent_id", `String intent.intent_id);
               ("workload_profile", `String "coding_task");
               ("stage", `String "verify");
               ("depends_on_operation_ids", `List [ `String shared_upstream.operation_id ]);
             ]));
      let forecast =
        unwrap_ok
          (Command_plane_v2.intent_forecast_json config intent.intent_id ())
      in
      Alcotest.(check (list string))
        "blocked_by empty when upstream has checkpoint"
        []
        (forecast |> Yojson.Safe.Util.member "blocked_by"
       |> Yojson.Safe.Util.to_list |> List.map Yojson.Safe.Util.to_string);
      Alcotest.(check bool) "verification gap risk cleared by checkpoint" false
        (forecast |> Yojson.Safe.Util.member "risk_flags"
       |> Yojson.Safe.Util.to_list
       |> List.exists (fun value ->
              String.equal (Yojson.Safe.Util.to_string value) "verification_gap")))

let test_checkpoint_preserves_terminal_intent_state () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let alpha_lead = "alpha-lead-node" in
      let alpha_two = "alpha-two-node" in
      with_eio_test base_dir @@ fun config ->
      setup_company_and_platoon config ~owner ~alpha_lead ~alpha_two;
      let intent =
        unwrap_ok
          (Command_plane_v2.create_intent_json config ~actor:"owner"
             (`Assoc [ ("title", `String "Terminal checkpoint preservation") ]))
      in
      let operation =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String "Complete and checkpoint");
              ("intent_id", `String intent.intent_id);
              ("workload_profile", `String "coding_task");
              ("stage", `String "implement");
            ])
      in
      ignore
        (unwrap_ok
           (Command_plane_v2.finalize_operation_json config ~actor:"owner"
              (`Assoc [ ("operation_id", `String operation.operation_id) ])));
      ignore
        (unwrap_ok
           (Command_plane_v2.checkpoint_operation config ~actor:"owner"
              (`Assoc
                [
                  ("operation_id", `String operation.operation_id);
                  ("checkpoint_ref", `String "late-terminal-checkpoint");
                ])));
      let intent_status =
        Command_plane_v2.list_intents_json ~intent_id:intent.intent_id config
      in
      Alcotest.(check string) "intent remains completed after late checkpoint"
        "completed"
        (intent_status |> Yojson.Safe.Util.member "intents"
       |> Yojson.Safe.Util.index 0
       |> Yojson.Safe.Util.member "state"
       |> Yojson.Safe.Util.to_string))

