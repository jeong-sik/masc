open Masc_mcp

let temp_dir () =
  let dir = Filename.temp_file "cp_search_fabric_benchmark_" "" in
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

let detachment_count config =
  Command_plane_v2.list_detachments_json config
  |> Yojson.Safe.Util.member "summary"
  |> Yojson.Safe.Util.member "total"
  |> Yojson.Safe.Util.to_int

let detachment_rows_for_operation config operation_id =
  Command_plane_v2.list_detachments_json ~operation_id config
  |> Yojson.Safe.Util.member "detachments"
  |> Yojson.Safe.Util.to_list

let setup_units config =
  let owner = "owner-root-node" in
  let normalize_lead = "normalize-lead-node" in
  let verify_lead = "verify-lead-node" in
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
          `List [ `String owner; `String normalize_lead; `String verify_lead ] );
      ]);
  unit_update_exn config ~actor:"owner"
    (`Assoc
      [
        ("unit_id", `String "platoon-research");
        ("kind", `String "platoon");
        ("label", `String "Research Platoon");
        ("parent_unit_id", `String "company-main");
        ("leader_id", `String owner);
        ("roster", `List [ `String normalize_lead; `String verify_lead ]);
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
            [ `String "normalize"; `String "research"; `String "research_pipeline" ] );
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
          `List [ `String "verify"; `String "research"; `String "research_pipeline" ] );
      ])

let run_scenario ~strategy =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      setup_units config;
      let started_at = Unix.gettimeofday () in
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
              ("search_strategy", `String strategy);
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
              ("search_strategy", `String strategy);
              ("depends_on_operation_ids", `List [ `String normalize_op.operation_id ]);
            ])
      in
      let initial_detachments = detachment_count config in
      let verify_plan_before =
        Command_plane_v2.dispatch_plan_json config
          (`Assoc [ ("operation_id", `String verify_op.operation_id) ])
      in
      let verify_blocked_before_checkpoint =
        match verify_plan_before |> Yojson.Safe.Util.member "readiness" with
        | `String "blocked" -> true
        | _ -> false
      in
      let verify_initial_detachments =
        List.length (detachment_rows_for_operation config verify_op.operation_id)
      in
      ignore
        (unwrap_ok
           (Command_plane_v2.dispatch_tick_json config ~actor:"owner"
              (`Assoc [ ("operation_id", `String normalize_op.operation_id) ])));
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
      let verify_detachments_after_tick =
        verify_tick |> Yojson.Safe.Util.member "summary"
        |> Yojson.Safe.Util.member "detachments_considered"
        |> Yojson.Safe.Util.to_int
      in
      let verify_rows = detachment_rows_for_operation config verify_op.operation_id in
      let verify_final_detachments = List.length verify_rows in
      let verify_assigned_unit =
        match verify_rows with
        | row :: _ ->
            row |> Yojson.Safe.Util.member "detachment"
            |> Yojson.Safe.Util.member "assigned_unit_id"
            |> Yojson.Safe.Util.to_string
        | [] -> "none"
      in
      let verify_status =
        match verify_rows with
        | row :: _ ->
            let detachment_id =
              row |> Yojson.Safe.Util.member "detachment"
              |> Yojson.Safe.Util.member "detachment_id"
              |> Yojson.Safe.Util.to_string
            in
            unwrap_ok
              (Command_plane_v2.detachment_status_json config
                 (`Assoc [ ("detachment_id", `String detachment_id) ]))
        | [] -> `Assoc [ ("result", `Assoc []) ]
      in
      let search_strategy_seen =
        match verify_status |> Yojson.Safe.Util.member "result" with
        | `Assoc _ ->
            verify_status |> Yojson.Safe.Util.member "result"
            |> Yojson.Safe.Util.member "search"
            |> Yojson.Safe.Util.member "strategy"
            |> Yojson.Safe.Util.to_string_option
        | _ -> None
      in
      let elapsed_ms =
        int_of_float ((Unix.gettimeofday () -. started_at) *. 1000.0)
      in
      `Assoc
        [
          ("strategy", `String strategy);
          ("initial_detachments", `Int initial_detachments);
          ("verify_blocked_before_checkpoint", `Bool verify_blocked_before_checkpoint);
          ("verify_initial_detachments", `Int verify_initial_detachments);
          ("verify_detachments_after_tick", `Int verify_detachments_after_tick);
          ("verify_final_detachments", `Int verify_final_detachments);
          ("verify_assigned_unit", `String verify_assigned_unit);
          ("elapsed_ms", `Int elapsed_ms);
          ( "search_strategy_seen",
            match search_strategy_seen with Some value -> `String value | None -> `Null );
        ])

let () =
  let legacy = run_scenario ~strategy:"legacy" in
  let best_first = run_scenario ~strategy:"best_first_v1" in
  let legacy_initial =
    legacy |> Yojson.Safe.Util.member "initial_detachments" |> Yojson.Safe.Util.to_int
  in
  let best_first_initial =
    best_first |> Yojson.Safe.Util.member "initial_detachments"
    |> Yojson.Safe.Util.to_int
  in
  Yojson.Safe.pretty_to_channel stdout
    (`Assoc
      [
        ("workload", `String "research_pipeline");
        ("legacy", legacy);
        ("best_first_v1", best_first);
        ( "delta",
          `Assoc
            [
              ("initial_detachments", `Int (best_first_initial - legacy_initial));
            ] );
      ]);
  print_newline ()
