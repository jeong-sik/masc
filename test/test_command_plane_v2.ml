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

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755

let write_json_file path json =
  ensure_dir (Filename.dirname path);
  Yojson.Safe.to_file path json

let write_text_file path content =
  ensure_dir (Filename.dirname path);
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let unwrap_ok = function
  | Ok value -> value
  | Error message -> failwith message

let unit_update_exn config ~actor args =
  ignore (unwrap_ok (Command_plane_v2.unit_update_json config ~actor args))

let start_operation_exn config ~actor args =
  unwrap_ok (Command_plane_v2.start_operation config ~actor args)

let setup_company_and_platoon config ~owner ~alpha_lead ~alpha_two =
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
        ("roster", `List [ `String owner; `String alpha_lead; `String alpha_two ]);
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
      ])

let detachment_rows_for_operation config operation_id =
  Command_plane_v2.list_detachments_json ~operation_id config
  |> Yojson.Safe.Util.member "detachments"
  |> Yojson.Safe.Util.to_list
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
      Alcotest.(check int) "alerts total" 0
        (snapshot |> Yojson.Safe.Util.member "alerts"
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

let test_swarm_live_json_restores_completed_workers_after_leave () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let run_id = "swarm-live-proof" in
      let plans = Agent_swarm_live_harness.build_worker_plans run_id in
      let worker_names =
        List.map
          (fun (plan : Agent_swarm_live_harness.worker_plan) -> plan.name)
          plans
      in
      let leader = List.hd worker_names in
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:owner ~capabilities:[] ());
      List.iter
        (fun worker -> ignore (Room.join config ~agent_name:worker ~capabilities:[] ()))
        worker_names;
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "company-main");
            ("kind", `String "company");
            ("label", `String "Main Company");
            ("leader_id", `String owner);
            ("roster", `List (List.map (fun name -> `String name) (owner :: worker_names)));
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "platoon-alpha");
            ("kind", `String "platoon");
            ("label", `String "Alpha Platoon");
            ("parent_unit_id", `String "company-main");
            ("leader_id", `String leader);
            ("roster", `List (List.map (fun name -> `String name) worker_names));
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "squad-alpha-1");
            ("kind", `String "squad");
            ("label", `String "Alpha Squad 1");
            ("parent_unit_id", `String "platoon-alpha");
            ("leader_id", `String leader);
            ("roster", `List (List.map (fun name -> `String name) worker_names));
          ]);
      let operation =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "squad-alpha-1");
              ("objective", `String (Printf.sprintf "Run %s live harness" run_id));
              ("note", `String (Printf.sprintf "run_id=%s" run_id));
              ("policy_class", `String "guarded");
              ("budget_class", `String "standard");
            ])
      in
      ignore
        (unwrap_ok
           (Command_plane_v2.dispatch_tick_json config ~actor:"owner"
              (`Assoc [ ("operation_id", `String operation.operation_id) ])));
      List.iteri
        (fun idx (plan : Agent_swarm_live_harness.worker_plan) ->
          ignore
            (Room.add_task config ~title:plan.task_title ~priority:2
               ~description:plan.task_description);
          let task_id = Printf.sprintf "task-%03d" (idx + 1) in
          ignore (Room.claim_task config ~agent_name:plan.name ~task_id);
          ignore (Room.broadcast config ~from_agent:plan.name
                    ~content:(Printf.sprintf "%s agent=%s task_id=%s"
                                plan.claim_marker plan.name task_id));
          ignore (Room.broadcast config ~from_agent:plan.name
                    ~content:(Printf.sprintf "%s agent=%s" plan.done_marker plan.name));
          ignore (Room.complete_task config ~agent_name:plan.name ~task_id
                    ~notes:plan.final_marker);
          ignore (Room.broadcast config ~from_agent:plan.name
                    ~content:(Printf.sprintf "%s agent=%s" plan.final_marker plan.name));
          ignore (Room.leave config ~agent_name:plan.name))
        plans;
      let artifact_dir =
        Filename.concat base_dir ".masc/control-plane/swarm-live/swarm-live-proof"
      in
      Room_utils.mkdir_p artifact_dir;
      Room_utils.write_json config
        (Filename.concat artifact_dir "swarm-live-summary.json")
        (`Assoc
          [
            ("run_id", `String run_id);
            ("worker_count", `Int 12);
            ("required_final_markers", `Int 12);
            ("completed_workers", `Int 12);
            ("final_markers_seen", `Int 12);
            ("pass_hot_concurrency", `Bool true);
            ("pass_end_to_end", `Bool true);
            ("pass", `Bool true);
            ("min_hot_slots", `Int 10);
          ]);
      Room_utils.write_json config
        (Filename.concat artifact_dir "slot-telemetry.json")
        (`Assoc
          [
            ("slot_url", `String "http://127.0.0.1:8085");
            ("total_slots", `Int 12);
            ("ctx_per_slot", `Int 262144);
            ("active_slots_now", `Int 0);
            ("peak_active_slots", `Int 12);
            ("sample_count", `Int 4);
            ("hot_window_ok", `Bool true);
            ("last_sample_at", `String (Types.now_iso ()));
            ( "timeline",
              `List
                [
                  `Assoc
                    [
                      ("timestamp", `String (Types.now_iso ()));
                      ("active_slots", `Int 12);
                      ("active_slot_ids", `List [ `Int 0; `Int 1; `Int 2; `Int 3 ]);
                    ];
                ] );
          ]);
      let swarm =
        Command_plane_v2.swarm_live_json config ~run_id ~operation_id:operation.operation_id ()
      in
      let swarm_by_operation_only =
        Command_plane_v2.swarm_live_json config ~operation_id:operation.operation_id ()
      in
      let open Yojson.Safe.Util in
      Alcotest.(check int) "joined workers" 12
        (swarm |> member "summary" |> member "joined_workers" |> to_int);
      Alcotest.(check int) "live workers drained" 0
        (swarm |> member "summary" |> member "live_workers" |> to_int);
      Alcotest.(check int) "task ownership restored" 12
        (swarm |> member "summary" |> member "current_task_bound" |> to_int);
      Alcotest.(check int) "completed workers" 12
        (swarm |> member "summary" |> member "completed_workers" |> to_int);
      Alcotest.(check int) "final markers seen" 12
        (swarm |> member "summary" |> member "final_markers_seen" |> to_int);
      Alcotest.(check int) "peak hot slots" 12
        (swarm |> member "summary" |> member "peak_hot_slots" |> to_int);
      Alcotest.(check bool) "hot pass" true
        (swarm |> member "summary" |> member "pass_hot_concurrency" |> to_bool);
      Alcotest.(check bool) "e2e pass" true
        (swarm |> member "summary" |> member "pass_end_to_end" |> to_bool);
      Alcotest.(check int) "provider total slots" 12
        (swarm |> member "provider" |> member "total_slots" |> to_int);
      Alcotest.(check string) "operation-only infers run id" run_id
        (swarm_by_operation_only |> member "run_id" |> to_string);
      Alcotest.(check int) "operation-only sees provider total slots" 12
        (swarm_by_operation_only |> member "provider" |> member "total_slots" |> to_int);
      Alcotest.(check bool) "swarm pass" true
        (swarm |> member "summary" |> member "pass" |> to_bool))
let test_swarm_live_json_ignores_stale_evidence_from_previous_run () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let run_id = "swarm-live-proof" in
      let plans = Agent_swarm_live_harness.build_worker_plans run_id in
      let worker_names =
        List.map
          (fun (plan : Agent_swarm_live_harness.worker_plan) -> plan.name)
          plans
      in
      let leader = List.hd worker_names in
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:owner ~capabilities:[] ());
      List.iter
        (fun worker -> ignore (Room.join config ~agent_name:worker ~capabilities:[] ()))
        worker_names;
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "company-main");
            ("kind", `String "company");
            ("label", `String "Main Company");
            ("leader_id", `String owner);
            ("roster", `List (List.map (fun name -> `String name) (owner :: worker_names)));
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "platoon-alpha");
            ("kind", `String "platoon");
            ("label", `String "Alpha Platoon");
            ("parent_unit_id", `String "company-main");
            ("leader_id", `String leader);
            ("roster", `List (List.map (fun name -> `String name) worker_names));
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "squad-alpha-1");
            ("kind", `String "squad");
            ("label", `String "Alpha Squad 1");
            ("parent_unit_id", `String "platoon-alpha");
            ("leader_id", `String leader);
            ("roster", `List (List.map (fun name -> `String name) worker_names));
          ]);
      let old_operation =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "squad-alpha-1");
              ("objective", `String (Printf.sprintf "Run %s live harness" run_id));
              ("note", `String (Printf.sprintf "run_id=%s" run_id));
              ("policy_class", `String "guarded");
              ("budget_class", `String "standard");
            ])
      in
      ignore
        (unwrap_ok
           (Command_plane_v2.dispatch_tick_json config ~actor:"owner"
              (`Assoc [ ("operation_id", `String old_operation.operation_id) ])));
      List.iteri
        (fun idx (plan : Agent_swarm_live_harness.worker_plan) ->
          ignore
            (Room.add_task config ~title:plan.task_title ~priority:2
               ~description:plan.task_description);
          let task_id = Printf.sprintf "task-%03d" (idx + 1) in
          ignore (Room.claim_task config ~agent_name:plan.name ~task_id);
          ignore (Room.broadcast config ~from_agent:plan.name
                    ~content:(Printf.sprintf "%s agent=%s task_id=%s"
                                plan.claim_marker plan.name task_id));
          ignore (Room.complete_task config ~agent_name:plan.name ~task_id
                    ~notes:plan.final_marker);
          ignore (Room.broadcast config ~from_agent:plan.name
                    ~content:(Printf.sprintf "%s agent=%s" plan.final_marker plan.name));
          ignore (Room.leave config ~agent_name:plan.name))
        plans;
      let artifact_dir =
        Filename.concat base_dir ".masc/control-plane/swarm-live/swarm-live-proof"
      in
      Room_utils.mkdir_p artifact_dir;
      Room_utils.write_json config
        (Filename.concat artifact_dir "swarm-live-summary.json")
        (`Assoc
          [
            ("run_id", `String run_id);
            ("worker_count", `Int 12);
            ("required_final_markers", `Int 12);
            ("completed_workers", `Int 12);
            ("final_markers_seen", `Int 12);
            ("pass_hot_concurrency", `Bool true);
            ("pass_end_to_end", `Bool true);
            ("pass", `Bool true);
            ("min_hot_slots", `Int 10);
          ]);
      ignore (Unix.sleepf 1.1);
      let fresh_operation =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String (Printf.sprintf "Run %s live harness again" run_id));
              ("note", `String (Printf.sprintf "run_id=%s" run_id));
              ("policy_class", `String "guarded");
              ("budget_class", `String "standard");
            ])
      in
      ignore
        (unwrap_ok
           (Command_plane_v2.dispatch_tick_json config ~actor:"owner"
              (`Assoc [ ("operation_id", `String fresh_operation.operation_id) ])));
      let swarm =
        Command_plane_v2.swarm_live_json config ~run_id ~operation_id:fresh_operation.operation_id ()
      in
      let open Yojson.Safe.Util in
      Alcotest.(check int) "joined workers reset" 0
        (swarm |> member "summary" |> member "joined_workers" |> to_int);
      Alcotest.(check int) "task ownership reset" 0
        (swarm |> member "summary" |> member "current_task_bound" |> to_int);
      Alcotest.(check int) "completed workers reset" 0
        (swarm |> member "summary" |> member "completed_workers" |> to_int);
      Alcotest.(check int) "final markers reset" 0
        (swarm |> member "summary" |> member "final_markers_seen" |> to_int);
      Alcotest.(check bool) "end to end fail" false
        (swarm |> member "summary" |> member "pass_end_to_end" |> to_bool))

let test_swarm_live_json_scopes_markers_to_sender () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let run_id = "swarm-live-replica-proof" in
      let plans =
        Agent_swarm_live_harness.build_worker_plans ~worker_count:13 run_id
      in
      let first_plan = List.hd plans in
      let replica_plan = List.nth plans 12 in
      let worker_names =
        List.map
          (fun (plan : Agent_swarm_live_harness.worker_plan) -> plan.name)
          plans
      in
      let leader = List.hd worker_names in
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:owner ~capabilities:[] ());
      List.iter
        (fun worker -> ignore (Room.join config ~agent_name:worker ~capabilities:[] ()))
        worker_names;
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "company-main");
            ("kind", `String "company");
            ("label", `String "Main Company");
            ("leader_id", `String owner);
            ("roster", `List (List.map (fun name -> `String name) (owner :: worker_names)));
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "platoon-alpha");
            ("kind", `String "platoon");
            ("label", `String "Alpha Platoon");
            ("parent_unit_id", `String "company-main");
            ("leader_id", `String leader);
            ("roster", `List (List.map (fun name -> `String name) worker_names));
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "squad-alpha-1");
            ("kind", `String "squad");
            ("label", `String "Alpha Squad 1");
            ("parent_unit_id", `String "platoon-alpha");
            ("leader_id", `String leader);
            ("roster", `List (List.map (fun name -> `String name) worker_names));
          ]);
      let operation =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "squad-alpha-1");
              ("objective", `String (Printf.sprintf "Run %s live harness" run_id));
              ("note", `String (Printf.sprintf "run_id=%s" run_id));
              ("policy_class", `String "guarded");
              ("budget_class", `String "standard");
            ])
      in
      ignore
        (unwrap_ok
           (Command_plane_v2.dispatch_tick_json config ~actor:"owner"
              (`Assoc [ ("operation_id", `String operation.operation_id) ])));
      Room_utils.mkdir_p
        (Filename.concat base_dir ".masc/control-plane/swarm-live/swarm-live-replica-proof");
      Room_utils.write_json config
        (Filename.concat base_dir
           ".masc/control-plane/swarm-live/swarm-live-replica-proof/swarm-live-summary.json")
        (`Assoc
          [
            ("run_id", `String run_id);
            ("worker_count", `Int 13);
            ("required_final_markers", `Int 13);
            ("completed_workers", `Int 1);
            ("final_markers_seen", `Int 1);
            ("pass_hot_concurrency", `Bool false);
            ("pass_end_to_end", `Bool false);
            ("pass", `Bool false);
            ("min_hot_slots", `Int 10);
          ]);
      ignore
        (Room.broadcast config ~from_agent:first_plan.name
           ~content:(Printf.sprintf "%s agent=%s"
                       first_plan.claim_marker first_plan.name));
      ignore
        (Room.broadcast config ~from_agent:first_plan.name
           ~content:(Printf.sprintf "%s agent=%s"
                       first_plan.done_marker first_plan.name));
      ignore
        (Room.broadcast config ~from_agent:first_plan.name
           ~content:(Printf.sprintf "%s agent=%s"
                       first_plan.final_marker first_plan.name));
      let swarm =
        Command_plane_v2.swarm_live_json config ~run_id
          ~operation_id:operation.operation_id ()
      in
      let open Yojson.Safe.Util in
      let workers = swarm |> member "workers" |> to_list in
      let find_worker name =
        workers
        |> List.find (fun row ->
               String.equal (row |> member "name" |> to_string) name)
      in
      let first_row = find_worker first_plan.name in
      let replica_row = find_worker replica_plan.name in
      Alcotest.(check bool) "first worker marker seen" true
        (first_row |> member "final_marker_seen" |> to_bool);
      Alcotest.(check bool) "replica marker not inherited" false
        (replica_row |> member "final_marker_seen" |> to_bool);
      Alcotest.(check bool) "replica claim not inherited" false
        (replica_row |> member "claim_marker_seen" |> to_bool))
let test_summary_json_omits_heavy_arrays_and_keeps_summaries () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let alpha_lead = "alpha-lead-node" in
      let alpha_two = "alpha-two-node" in
      let config = Room.default_config base_dir in
      setup_company_and_platoon config ~owner ~alpha_lead ~alpha_two;
      ignore
        (start_operation_exn config ~actor:"owner"
           (`Assoc
             [
               ("assigned_unit_id", `String "platoon-alpha");
               ("objective", `String "Run summary drill");
               ("policy_class", `String "guarded");
               ("budget_class", `String "standard");
             ]));
      let summary = Command_plane_v2.summary_json config in
      Alcotest.(check int) "summary topology active ops" 1
        (summary |> Yojson.Safe.Util.member "topology"
       |> Yojson.Safe.Util.member "summary"
       |> Yojson.Safe.Util.member "active_operation_count"
       |> Yojson.Safe.Util.to_int);
      Alcotest.(check int) "summary operations total" 1
        (summary |> Yojson.Safe.Util.member "operations"
       |> Yojson.Safe.Util.member "summary"
       |> Yojson.Safe.Util.member "total"
       |> Yojson.Safe.Util.to_int);
      Alcotest.(check bool) "topology units omitted" true
        (summary |> Yojson.Safe.Util.member "topology"
       |> Yojson.Safe.Util.member "units" = `Null);
      Alcotest.(check bool) "operations list omitted" true
        (summary |> Yojson.Safe.Util.member "operations"
       |> Yojson.Safe.Util.member "operations" = `Null);
      Alcotest.(check bool) "detachments list omitted" true
        (summary |> Yojson.Safe.Util.member "detachments"
       |> Yojson.Safe.Util.member "detachments" = `Null);
      Alcotest.(check bool) "traces omitted at root" true
        (summary |> Yojson.Safe.Util.member "traces" = `Null);
      Alcotest.(check bool) "swarm proof included" true
        (summary |> Yojson.Safe.Util.member "swarm_proof" <> `Null))

let test_summary_json_swarm_proof_prefers_artifact () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      let run_dir =
        Filename.concat
          (Filename.concat (Filename.concat (Room.masc_dir config) "control-plane") "swarm-live")
          "run-artifact"
      in
      write_json_file (Filename.concat run_dir "swarm-live-summary.json")
        (`Assoc
          [
            ("pass", `Bool true);
            ("worker_count", `Int 4);
            ("completed_workers", `Int 3);
            ("final_markers_seen", `Int 2);
          ]);
      write_text_file (Filename.concat run_dir "slot-samples.jsonl")
        "{\"timestamp\":\"2026-03-08T00:00:00Z\",\"active_slots\":5,\"ctx_per_slot\":1200}\n";
      let summary = Command_plane_v2.summary_json config in
      let proof = Yojson.Safe.Util.member "swarm_proof" summary in
      Alcotest.(check string) "artifact status" "present"
        (proof |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
      Alcotest.(check string) "artifact source" "artifact"
        (proof |> Yojson.Safe.Util.member "source" |> Yojson.Safe.Util.to_string);
      Alcotest.(check string) "artifact run id" "run-artifact"
        (proof |> Yojson.Safe.Util.member "run_id" |> Yojson.Safe.Util.to_string);
      Alcotest.(check bool) "artifact pass" true
        (proof |> Yojson.Safe.Util.member "pass" |> Yojson.Safe.Util.to_bool);
      Alcotest.(check int) "artifact worker expected" 4
        (proof |> Yojson.Safe.Util.member "workers"
       |> Yojson.Safe.Util.member "expected"
       |> Yojson.Safe.Util.to_int);
      Alcotest.(check int) "artifact peak hot slots" 5
        (proof |> Yojson.Safe.Util.member "peak_hot_slots"
       |> Yojson.Safe.Util.to_int))

let test_summary_json_swarm_proof_fallback_and_missing () =
  let fallback_dir = temp_dir () in
  let missing_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      cleanup_dir fallback_dir;
      cleanup_dir missing_dir)
    (fun () ->
      let fallback_config = Room.default_config fallback_dir in
      ignore (Room.init fallback_config ~agent_name:(Some "owner"));
      let run_dir =
        Filename.concat
          (Filename.concat (Filename.concat (Room.masc_dir fallback_config) "control-plane") "swarm-live")
          "run-fallback"
      in
      write_text_file (Filename.concat run_dir "slot-samples.jsonl")
        "{\"timestamp\":\"2026-03-08T01:00:00Z\",\"active_slots\":2,\"ctx_per_slot\":800}\n";
      let fallback_summary = Command_plane_v2.summary_json fallback_config in
      let fallback_proof = Yojson.Safe.Util.member "swarm_proof" fallback_summary in
      Alcotest.(check string) "fallback status" "fallback"
        (fallback_proof |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
      Alcotest.(check string) "fallback source" "slot_samples"
        (fallback_proof |> Yojson.Safe.Util.member "source" |> Yojson.Safe.Util.to_string);
      Alcotest.(check string) "fallback run id" "run-fallback"
        (fallback_proof |> Yojson.Safe.Util.member "run_id" |> Yojson.Safe.Util.to_string);
      Alcotest.(check bool) "fallback pass omitted" true
        (fallback_proof |> Yojson.Safe.Util.member "pass" = `Null);
      let missing_config = Room.default_config missing_dir in
      ignore (Room.init missing_config ~agent_name:(Some "owner"));
      let missing_summary = Command_plane_v2.summary_json missing_config in
      let missing_proof = Yojson.Safe.Util.member "swarm_proof" missing_summary in
      Alcotest.(check string) "missing status" "missing"
        (missing_proof |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
      Alcotest.(check string) "missing source" "none"
        (missing_proof |> Yojson.Safe.Util.member "source" |> Yojson.Safe.Util.to_string);
      Alcotest.(check bool) "missing reason present" true
        (missing_proof |> Yojson.Safe.Util.member "missing_reason" <> `Null))
let test_swarm_live_json_reads_custom_worker_count_from_operation_note () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let run_id = "swarm-live-custom-count" in
      let plans =
        Agent_swarm_live_harness.build_worker_plans ~worker_count:13 run_id
      in
      let worker_names =
        List.map
          (fun (plan : Agent_swarm_live_harness.worker_plan) -> plan.name)
          plans
      in
      let leader = List.hd worker_names in
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:owner ~capabilities:[] ());
      List.iter
        (fun worker ->
          ignore (Room.join config ~agent_name:worker ~capabilities:[] ()))
        worker_names;
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "company-main");
            ("kind", `String "company");
            ("label", `String "Main Company");
            ("leader_id", `String owner);
            ( "roster",
              `List
                (List.map (fun name -> `String name) (owner :: worker_names))
            );
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "platoon-alpha");
            ("kind", `String "platoon");
            ("label", `String "Alpha Platoon");
            ("parent_unit_id", `String "company-main");
            ("leader_id", `String leader);
            ("roster", `List (List.map (fun name -> `String name) worker_names));
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "squad-alpha-1");
            ("kind", `String "squad");
            ("label", `String "Alpha Squad 1");
            ("parent_unit_id", `String "platoon-alpha");
            ("leader_id", `String leader);
            ("roster", `List (List.map (fun name -> `String name) worker_names));
          ]);
      let operation =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "squad-alpha-1");
              ( "objective",
                `String
                  (Printf.sprintf "Run deterministic 13-worker live harness %s"
                     run_id) );
              ( "note",
                `String
                  (Printf.sprintf
                     "run_id=%s worker_count=13 required_final_markers=13 min_hot_slots=11"
                     run_id) );
              ("policy_class", `String "guarded");
              ("budget_class", `String "standard");
            ])
      in
      ignore
        (unwrap_ok
           (Command_plane_v2.dispatch_tick_json config ~actor:"owner"
              (`Assoc [ ("operation_id", `String operation.operation_id) ])));
      let swarm =
        Command_plane_v2.swarm_live_json config ~run_id
          ~operation_id:operation.operation_id ()
      in
      let open Yojson.Safe.Util in
      Alcotest.(check int) "expected workers from note" 13
        (swarm |> member "summary" |> member "expected_workers" |> to_int);
      Alcotest.(check int) "worker rows from note" 13
        (swarm |> member "workers" |> to_list |> List.length);
      Alcotest.(check int) "live workers from joined roster" 13
        (swarm |> member "summary" |> member "live_workers" |> to_int))

let test_best_first_search_blocks_and_routes_research_pipeline () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let normalize_lead = "normalize-lead-node" in
      let verify_lead = "verify-lead-node" in
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:owner ~capabilities:[] ());
      ignore (Room.join config ~agent_name:normalize_lead ~capabilities:[] ());
      ignore (Room.join config ~agent_name:verify_lead ~capabilities:[] ());
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "company-main");
            ("kind", `String "company");
            ("label", `String "Main Company");
            ("leader_id", `String owner);
            ( "roster",
              `List
                [ `String owner; `String normalize_lead; `String verify_lead ] );
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "platoon-research");
            ("kind", `String "platoon");
            ("label", `String "Research Platoon");
            ("parent_unit_id", `String "company-main");
            ("leader_id", `String owner);
            ( "roster",
              `List [ `String normalize_lead; `String verify_lead ] );
            ("capability_profile", `List [ `String "research"; `String "research_pipeline" ]);
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "squad-normalize");
            ("kind", `String "squad");
            ("label", `String "Normalize Squad");
            ("parent_unit_id", `String "platoon-research");
            ("leader_id", `String normalize_lead);
            ("roster", `List [ `String normalize_lead ]);
            ( "capability_profile",
              `List
                [
                  `String "normalize";
                  `String "research";
                  `String "research_pipeline";
                ] );
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "squad-verify");
            ("kind", `String "squad");
            ("label", `String "Verify Squad");
            ("parent_unit_id", `String "platoon-research");
            ("leader_id", `String verify_lead);
            ("roster", `List [ `String verify_lead ]);
            ( "capability_profile",
              `List
                [
                  `String "verify";
                  `String "research";
                  `String "research_pipeline";
                ] );
          ]);
      let normalize_op =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "platoon-research");
              ("objective", `String "Normalize research items");
              ("policy_class", `String "guarded");
              ("budget_class", `String "standard");
              ("workload_profile", `String "research_pipeline");
              ("stage", `String "normalize");
              ("search_strategy", `String "best_first_v1");
            ])
      in
      let verify_op =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "platoon-research");
              ("objective", `String "Verify research items");
              ("policy_class", `String "guarded");
              ("budget_class", `String "standard");
              ("workload_profile", `String "research_pipeline");
              ("stage", `String "verify");
              ("search_strategy", `String "best_first_v1");
              ( "depends_on_operation_ids",
                `List [ `String normalize_op.operation_id ] );
            ])
      in
      let verify_plan_before = Command_plane_v2.dispatch_plan_json config
        (`Assoc [ ("operation_id", `String verify_op.operation_id) ])
      in
      Alcotest.(check string) "verify initially blocked" "blocked"
        (verify_plan_before |> Yojson.Safe.Util.member "readiness"
       |> Yojson.Safe.Util.to_string);
      Alcotest.(check int) "one dependency blocker" 1
        (verify_plan_before |> Yojson.Safe.Util.member "dependency_blockers"
       |> Yojson.Safe.Util.to_list |> List.length);
      Alcotest.(check bool) "score breakdown exposed" true
        (verify_plan_before |> Yojson.Safe.Util.member "recommended_units"
       |> Yojson.Safe.Util.index 0 |> Yojson.Safe.Util.member "score_breakdown"
       <> `Null);
      Alcotest.(check int) "verify has no detachment while blocked" 0
        (List.length (detachment_rows_for_operation config verify_op.operation_id));
      ignore
        (unwrap_ok
           (Command_plane_v2.dispatch_tick_json config ~actor:"owner"
              (`Assoc [ ("operation_id", `String normalize_op.operation_id) ])));
      let normalize_state =
        Command_plane_v2.operation_status_json config
          ~operation_id:normalize_op.operation_id ()
      in
      let normalize_assigned_unit =
        normalize_state |> Yojson.Safe.Util.member "operations"
        |> Yojson.Safe.Util.index 0
        |> Yojson.Safe.Util.member "operation"
        |> Yojson.Safe.Util.member "assigned_unit_id"
        |> Yojson.Safe.Util.to_string
      in
      Alcotest.(check string) "normalize routed to normalize squad"
        "squad-normalize" normalize_assigned_unit;
      ignore
        (unwrap_ok
           (Command_plane_v2.checkpoint_operation config ~actor:"owner"
              (`Assoc
                [
                  ("operation_id", `String normalize_op.operation_id);
                  ("checkpoint_ref", `String "ckpt-normalize-1");
                ])));
      let verify_tick =
        unwrap_ok
          (Command_plane_v2.dispatch_tick_json config ~actor:"owner"
             (`Assoc [ ("operation_id", `String verify_op.operation_id) ]))
      in
      Alcotest.(check int) "verify detachment materialized after upstream checkpoint" 1
        (verify_tick |> Yojson.Safe.Util.member "summary"
       |> Yojson.Safe.Util.member "detachments_considered"
       |> Yojson.Safe.Util.to_int);
      let verify_rows = detachment_rows_for_operation config verify_op.operation_id in
      Alcotest.(check int) "verify now has one detachment" 1 (List.length verify_rows);
      let detachment_id =
        verify_rows |> List.hd |> Yojson.Safe.Util.member "detachment"
        |> Yojson.Safe.Util.member "detachment_id"
        |> Yojson.Safe.Util.to_string
      in
      let verify_status =
        unwrap_ok
          (Command_plane_v2.detachment_status_json config
             (`Assoc [ ("detachment_id", `String detachment_id) ]))
      in
      Alcotest.(check string) "verify routed to verify squad"
        "squad-verify"
        (verify_status |> Yojson.Safe.Util.member "result"
       |> Yojson.Safe.Util.member "detachment"
       |> Yojson.Safe.Util.member "assigned_unit_id"
       |> Yojson.Safe.Util.to_string);
      Alcotest.(check string) "detachment status exposes search strategy"
        "best_first_v1"
        (verify_status |> Yojson.Safe.Util.member "result"
       |> Yojson.Safe.Util.member "search"
       |> Yojson.Safe.Util.member "strategy"
       |> Yojson.Safe.Util.to_string);
      let operations_overview =
        Command_plane_v2.list_operations_json config
      in
      Alcotest.(check bool) "operations overview exposes microarch summary" true
        (operations_overview |> Yojson.Safe.Util.member "microarch" <> `Null);
      Alcotest.(check bool) "microarch exposes search fabric summary" true
        (operations_overview |> Yojson.Safe.Util.member "microarch"
       |> Yojson.Safe.Util.member "search_fabric" <> `Null);
      Alcotest.(check bool) "microarch exposes operator signals" true
        (operations_overview |> Yojson.Safe.Util.member "microarch"
       |> Yojson.Safe.Util.member "signals" <> `Null))

let test_invalid_search_strategy_is_rejected () =
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
      match
        Command_plane_v2.start_operation config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "company-main");
              ("objective", `String "Reject invalid strategy");
              ("search_strategy", `String "made_up_strategy");
            ])
      with
      | Ok _ -> Alcotest.fail "invalid search_strategy should be rejected"
      | Error message ->
          Alcotest.(check string) "validation error"
            "unsupported search_strategy: made_up_strategy" message)

let () =
  Alcotest.run "Command_plane_v2"
    [
      ( "scheduler",
        [
          Alcotest.test_case "platoon assignment expands detachments" `Quick
            test_platoon_assignment_expands_detachments_and_tick_runs;
          Alcotest.test_case "invalid search strategy is rejected" `Quick
            test_invalid_search_strategy_is_rejected;
          Alcotest.test_case "best first search blocks and routes research pipeline"
            `Quick
            test_best_first_search_blocks_and_routes_research_pipeline;
          Alcotest.test_case "freeze requires company approval" `Quick
            test_freeze_requires_company_approval;
          Alcotest.test_case "snapshot json reports consistent sections" `Quick
            test_snapshot_json_reports_consistent_sections;
          Alcotest.test_case "swarm live restores completed workers" `Quick
            test_swarm_live_json_restores_completed_workers_after_leave;
          Alcotest.test_case "swarm live ignores stale previous-run evidence" `Quick
            test_swarm_live_json_ignores_stale_evidence_from_previous_run;
          Alcotest.test_case "swarm live scopes markers to sender" `Quick
            test_swarm_live_json_scopes_markers_to_sender;
          Alcotest.test_case "swarm live reads custom worker count from operation note" `Quick
            test_swarm_live_json_reads_custom_worker_count_from_operation_note;
          Alcotest.test_case "summary json omits heavy arrays" `Quick
            test_summary_json_omits_heavy_arrays_and_keeps_summaries;
          Alcotest.test_case "summary swarm proof prefers artifact" `Quick
            test_summary_json_swarm_proof_prefers_artifact;
          Alcotest.test_case "summary swarm proof fallback and missing" `Quick
            test_summary_json_swarm_proof_fallback_and_missing;
        ] );
    ]
