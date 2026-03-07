open Masc_mcp

let temp_dir () =
  let dir = Filename.temp_file "test_command_plane_v2_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let unwrap_ok = function
  | Ok value -> value
  | Error message -> failwith message

let unit_update_exn config ~actor args =
  ignore (unwrap_ok (Command_plane_v2.unit_update_json config ~actor args))

let start_operation_exn config ~actor args =
  unwrap_ok (Command_plane_v2.start_operation config ~actor args)

let test_platoon_assignment_expands_detachments_and_tick_runs () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let alpha_lead = "alpha-lead-node" in
      let alpha_two = "alpha-two-node" in
      let beta_lead = "beta-lead-node" in
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:owner ~capabilities:[] ());
      ignore (Room.join config ~agent_name:alpha_lead ~capabilities:[] ());
      ignore (Room.join config ~agent_name:alpha_two ~capabilities:[] ());
      ignore (Room.join config ~agent_name:beta_lead ~capabilities:[] ());
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "company-main");
            ("kind", `String "company");
            ("label", `String "Main Company");
            ("leader_id", `String owner);
            ( "roster",
              `List
                [
                  `String owner;
                  `String alpha_lead;
                  `String alpha_two;
                  `String beta_lead;
                ] );
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "platoon-alpha");
            ("kind", `String "platoon");
            ("label", `String "Alpha Platoon");
            ("parent_unit_id", `String "company-main");
            ("leader_id", `String alpha_lead);
            ( "roster",
              `List
                [
                  `String alpha_lead;
                  `String alpha_two;
                  `String beta_lead;
                ] );
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "squad-alpha-1");
            ("kind", `String "squad");
            ("label", `String "Alpha Squad 1");
            ("parent_unit_id", `String "platoon-alpha");
            ("leader_id", `String alpha_lead);
            ("roster", `List [ `String alpha_lead; `String alpha_two ]);
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "squad-alpha-2");
            ("kind", `String "squad");
            ("label", `String "Alpha Squad 2");
            ("parent_unit_id", `String "platoon-alpha");
            ("leader_id", `String beta_lead);
            ("roster", `List [ `String beta_lead ]);
          ]);
      let operation =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "platoon-alpha");
              ("objective", `String "Run platoon-level rehearsal");
              ("policy_class", `String "guarded");
              ("budget_class", `String "standard");
            ])
      in
      let detachments_json =
        Command_plane_v2.list_detachments_json ~operation_id:operation.operation_id config
      in
      let detachments =
        detachments_json |> Yojson.Safe.Util.member "detachments"
        |> Yojson.Safe.Util.to_list
      in
      Alcotest.(check int) "expanded to both squads" 2 (List.length detachments);
      List.iter
        (fun row ->
          let detachment = Yojson.Safe.Util.member "detachment" row in
          Alcotest.(check bool) "runtime kind present" true
            (Yojson.Safe.Util.member "runtime_kind" detachment <> `Null);
          Alcotest.(check bool) "heartbeat deadline present" true
            (Yojson.Safe.Util.member "heartbeat_deadline" detachment <> `Null))
        detachments;
      let tick_json =
        unwrap_ok
          (Command_plane_v2.dispatch_tick_json config ~actor:"owner"
             (`Assoc [ ("operation_id", `String operation.operation_id) ]))
      in
      Alcotest.(check string) "tick ok" "ok"
        (tick_json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
      Alcotest.(check int) "tick considers two detachments" 2
        (tick_json |> Yojson.Safe.Util.member "summary"
       |> Yojson.Safe.Util.member "detachments_considered"
       |> Yojson.Safe.Util.to_int);
      Alcotest.(check int) "fresh detachments are not stale" 0
        (tick_json |> Yojson.Safe.Util.member "summary"
       |> Yojson.Safe.Util.member "stale_detachments"
       |> Yojson.Safe.Util.to_int);
      Alcotest.(check int) "no escalation on fresh detachments" 0
        (tick_json |> Yojson.Safe.Util.member "summary"
       |> Yojson.Safe.Util.member "escalations_requested"
       |> Yojson.Safe.Util.to_int))

let test_freeze_requires_company_approval () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:owner ~capabilities:[] ());
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "company-main");
            ("kind", `String "company");
            ("label", `String "Main Company");
            ("leader_id", `String owner);
            ("roster", `List [ `String owner ]);
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "platoon-alpha");
            ("kind", `String "platoon");
            ("label", `String "Alpha Platoon");
            ("parent_unit_id", `String "company-main");
            ("leader_id", `String owner);
            ("roster", `List [ `String owner ]);
          ]);
      let response =
        unwrap_ok
          (Command_plane_v2.policy_freeze_unit_json config ~actor:"owner"
             (`Assoc
               [
                 ("unit_id", `String "platoon-alpha");
                 ("enabled", `Bool true);
               ]))
      in
      Alcotest.(check string) "freeze pending approval" "pending_approval"
        (response |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
      Alcotest.(check bool) "decision id present" true
        (response |> Yojson.Safe.Util.member "decision"
       |> Yojson.Safe.Util.member "decision_id"
       <> `Null))

let test_snapshot_json_reports_consistent_sections () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let alpha_lead = "alpha-lead-node" in
      let alpha_two = "alpha-two-node" in
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:owner ~capabilities:[] ());
      ignore (Room.join config ~agent_name:alpha_lead ~capabilities:[] ());
      ignore (Room.join config ~agent_name:alpha_two ~capabilities:[] ());
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "company-main");
            ("kind", `String "company");
            ("label", `String "Main Company");
            ("leader_id", `String owner);
            ( "roster",
              `List
                [ `String owner; `String alpha_lead; `String alpha_two ] );
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "platoon-alpha");
            ("kind", `String "platoon");
            ("label", `String "Alpha Platoon");
            ("parent_unit_id", `String "company-main");
            ("leader_id", `String alpha_lead);
            ("roster", `List [ `String alpha_lead; `String alpha_two ]);
          ]);
      let operation =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "platoon-alpha");
              ("objective", `String "Run snapshot drill");
              ("policy_class", `String "guarded");
              ("budget_class", `String "standard");
            ])
      in
      let snapshot = Command_plane_v2.snapshot_json config in
      Alcotest.(check int) "topology active operations" 1
        (snapshot |> Yojson.Safe.Util.member "topology"
       |> Yojson.Safe.Util.member "summary"
       |> Yojson.Safe.Util.member "active_operation_count"
       |> Yojson.Safe.Util.to_int);
      Alcotest.(check int) "operations total" 1
        (snapshot |> Yojson.Safe.Util.member "operations"
       |> Yojson.Safe.Util.member "summary"
       |> Yojson.Safe.Util.member "total"
       |> Yojson.Safe.Util.to_int);
      Alcotest.(check int) "detachments total" 1
        (snapshot |> Yojson.Safe.Util.member "detachments"
       |> Yojson.Safe.Util.member "summary"
       |> Yojson.Safe.Util.member "total"
       |> Yojson.Safe.Util.to_int);
      Alcotest.(check string) "operation objective retained" "Run snapshot drill"
        (snapshot |> Yojson.Safe.Util.member "operations"
       |> Yojson.Safe.Util.member "operations"
       |> Yojson.Safe.Util.index 0
       |> Yojson.Safe.Util.member "operation"
       |> Yojson.Safe.Util.member "objective"
       |> Yojson.Safe.Util.to_string);
      Alcotest.(check bool) "operation trace shows up" true
        (snapshot |> Yojson.Safe.Util.member "traces"
       |> Yojson.Safe.Util.member "events"
       |> Yojson.Safe.Util.to_list
       |> List.exists (fun row ->
              match Yojson.Safe.Util.member "operation_id" row with
              | `String value -> String.equal value operation.operation_id
              | _ -> false)))

let () =
  Alcotest.run "Command_plane_v2"
    [
      ( "scheduler",
        [
          Alcotest.test_case "platoon assignment expands detachments" `Quick
            test_platoon_assignment_expands_detachments_and_tick_runs;
          Alcotest.test_case "freeze requires company approval" `Quick
            test_freeze_requires_company_approval;
          Alcotest.test_case "snapshot json reports consistent sections" `Quick
            test_snapshot_json_reports_consistent_sections;
        ] );
    ]
