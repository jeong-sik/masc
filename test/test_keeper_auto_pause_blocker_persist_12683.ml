(** #12683 — pin that auto-pause paths write structured [last_blocker]
    into keeper_meta so the blocker survives
    supervisor unregister/restart.

    Structural fact this test pins: a meta JSON written with
    structured [last_blocker] round-trips through
    serialization/deserialization without loss, so the blocker survives
    server restart.

    (Legacy ["oas_timeout_budget"] wire mapping was retired by #17805;
    related test rows have been removed accordingly.) *)

open Alcotest
module KT = Masc_mcp.Keeper_types
module MC = Masc_mcp.Keeper_meta_contract

let test_turn_timeout_blocker_class_roundtrip () =
  let cls = KT.Turn_timeout in
  let label = KT.blocker_class_to_string cls in
  check bool "label non-empty" true (String.length label > 0);
  match MC.blocker_class_of_serialized_string label with
  | Some _ -> ()
  | None -> fail "Turn_timeout label did not parse back"

let test_stale_fleet_batch_blocker_class_roundtrip () =
  let cls = KT.Stale_fleet_batch in
  let label = KT.blocker_class_to_string cls in
  check string "label" "stale_fleet_batch" label;
  match MC.blocker_class_of_serialized_string label with
  | Some MC.Stale_fleet_batch -> ()
  | Some _ -> fail "Stale_fleet_batch label parsed as wrong class"
  | None -> fail "Stale_fleet_batch label did not parse back"

let test_capacity_backpressure_blocker_class_roundtrip () =
  let cls = KT.Capacity_backpressure in
  let label = KT.blocker_class_to_string cls in
  check string "label" "capacity_backpressure" label;
  match MC.blocker_class_of_serialized_string label with
  | Some MC.Capacity_backpressure -> ()
  | Some _ -> fail "Capacity_backpressure label parsed as wrong class"
  | None -> fail "Capacity_backpressure label did not parse back"

let test_meta_json_roundtrip_with_auto_pause_blocker () =
  let base_json = `Assoc [
    ("name", `String "test-keeper");
    ("agent_name", `String "agent-test");
    ("trace_id", `String "trace-test");
    ("goal", `String "test");
    ("sandbox_profile", `String "local");
    ("network_mode", `String "inherit");
  ] in
  let meta = match KT.meta_of_json base_json with
    | Ok m -> m
    | Error err -> fail ("parse base: " ^ err)
  in
  let blocker_text = "oas_timeout_budget" in
  let paused_meta = { meta with
    paused = true;
    auto_resume_after_sec = Some 3600.0;
    runtime = { meta.runtime with
      last_blocker =
        Some (KT.blocker_info_of_class
                ~detail:blocker_text KT.Turn_timeout);
    };
  } in
  let json = KT.meta_to_json paused_meta in
  let reparsed = match KT.meta_of_json json with
    | Ok m -> m
    | Error err -> fail ("roundtrip: " ^ err)
  in
  check bool "paused" true reparsed.paused;
  check (option (float 0.1)) "auto_resume_after_sec"
    (Some 3600.0) reparsed.auto_resume_after_sec;
  (match reparsed.runtime.last_blocker with
   | Some info ->
     check string "last_blocker.detail preserved" blocker_text info.detail;
     (match info.klass with
      | KT.Turn_timeout -> ()
      | _ -> fail "legacy timeout-budget blocker did not collapse to Turn_timeout")
   | None -> fail "last_blocker should be Some after roundtrip")

let test_meta_json_roundtrip_with_stale_storm_blocker () =
  let base_json = `Assoc [
    ("name", `String "test-keeper2");
    ("agent_name", `String "agent-test2");
    ("trace_id", `String "trace-test2");
    ("goal", `String "test");
    ("sandbox_profile", `String "local");
    ("network_mode", `String "inherit");
  ] in
  let meta = match KT.meta_of_json base_json with
    | Ok m -> m
    | Error err -> fail ("parse base: " ^ err)
  in
  let blocker_text = KT.blocker_class_to_string KT.Turn_timeout in
  let paused_meta = { meta with
    paused = true;
    auto_resume_after_sec = Some 7200.0;
    runtime = { meta.runtime with
      last_blocker =
        Some (KT.blocker_info_of_class
                ~detail:blocker_text KT.Turn_timeout);
    };
  } in
  let json = KT.meta_to_json paused_meta in
  let reparsed = match KT.meta_of_json json with
    | Ok m -> m
    | Error err -> fail ("roundtrip: " ^ err)
  in
  (match reparsed.runtime.last_blocker with
   | Some info ->
     check string "last_blocker.detail" blocker_text info.detail;
     (match info.klass with
      | KT.Turn_timeout -> ()
      | _ -> fail "blocker klass not Turn_timeout after roundtrip")
   | None -> fail "last_blocker should be Some after roundtrip")

let legacy_base_json name =
  `Assoc
    [
      "name", `String name;
      "agent_name", `String (name ^ "-agent");
      "trace_id", `String ("trace-" ^ name);
      "goal", `String "test";
      "sandbox_profile", `String "local";
      "network_mode", `String "inherit";
    ]

let test_legacy_last_blocker_pair_rejected () =
  let legacy_json =
    match legacy_base_json "legacy-blocker-pair" with
    | `Assoc fields ->
      `Assoc
        (fields
         @ [
           "last_blocker", `String "turn wall-clock timeout exceeded";
           "last_blocker_class", `String "turn_timeout";
         ])
    | json -> json
  in
  match KT.meta_of_json legacy_json with
  | Ok _ -> fail "legacy blocker pair should be rejected"
  | Error msg ->
    check string
      "rejects legacy blocker class"
      "legacy keeper meta fields are no longer supported: last_blocker_class"
      msg

let test_legacy_last_blocker_string_rejected () =
  let legacy_json =
    match legacy_base_json "legacy-blocker-string" with
    | `Assoc fields ->
      `Assoc
        (fields @ [ "last_blocker", `String "turn wall-clock timeout exceeded" ])
    | json -> json
  in
  match KT.meta_of_json legacy_json with
  | Ok _ -> fail "legacy string last_blocker should be rejected"
  | Error msg ->
    check string
      "rejects string last_blocker"
      "legacy keeper meta field shape is no longer supported: \
       last_blocker:string. Use structured last_blocker object."
      msg

let test_repo_cli_identity_runtime_meta_rejected () =
  let legacy_json =
    match legacy_base_json "legacy-github-identity" with
    | `Assoc fields ->
      `Assoc (fields @ [ "repo_cli_identity", `String "anyang-keepers" ])
    | json -> json
  in
  match KT.meta_of_json legacy_json with
  | Ok _ -> fail "runtime meta repo_cli_identity field should be rejected"
  | Error msg ->
    check string
      "rejects repo_cli_identity"
      "legacy keeper meta fields are no longer supported: repo_cli_identity"
      msg

let has_key key = function
  | `Assoc fields -> List.mem_assoc key fields
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> false

let retired_discovery_key suffix = "work_" ^ "discovery" ^ suffix

let test_persisted_retired_runtime_meta_fields_scrubbed () =
  let retired_fields =
    [
      "repo_cli_identity", `String "anyang-keepers";
      "last_" ^ retired_discovery_key "_ts", `String "2026-05-24T16:29:11Z";
      retired_discovery_key "_count", `Int 12;
      retired_discovery_key "_enabled", `Bool true;
      retired_discovery_key "_sources", `List [ `String "taskboard" ];
      retired_discovery_key "_interval_sec", `Int 60;
      retired_discovery_key "_guidance", `String "legacy guidance";
    ]
  in
  let legacy_json =
    match legacy_base_json "persisted-retired-fields" with
    | `Assoc fields -> `Assoc (fields @ retired_fields)
    | json -> json
  in
  let path = Filename.temp_file "keeper-retired-meta-" ".json" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
       Yojson.Safe.to_file path legacy_json;
       let scrubbed, changed = KT.scrub_persisted_keeper_meta_json ~path legacy_json in
       check bool "scrubbed" true changed;
       List.iter
         (fun (key, _) -> check bool (key ^ " removed") false (has_key key scrubbed))
         retired_fields;
       (match KT.meta_of_json scrubbed with
        | Ok _ -> ()
        | Error err -> fail ("scrubbed meta should parse: " ^ err));
       let persisted = Yojson.Safe.from_file path in
       List.iter
         (fun (key, _) -> check bool (key ^ " persisted removed") false (has_key key persisted))
         retired_fields)

let () =
  run "keeper_auto_pause_blocker_persist_12683"
    [
      ( "blocker_class labels",
        [
          test_case "Turn_timeout roundtrip" `Quick
            test_turn_timeout_blocker_class_roundtrip;
          test_case "Stale_fleet_batch roundtrip" `Quick
            test_stale_fleet_batch_blocker_class_roundtrip;
          test_case "Capacity_backpressure roundtrip" `Quick
            test_capacity_backpressure_blocker_class_roundtrip;
        ] );
      ( "meta JSON roundtrip",
        [
          test_case "OAS budget blocker survives serialization" `Quick
            test_meta_json_roundtrip_with_auto_pause_blocker;
          test_case "stale storm blocker survives serialization" `Quick
            test_meta_json_roundtrip_with_stale_storm_blocker;
          test_case "legacy blocker pair rejected" `Quick
            test_legacy_last_blocker_pair_rejected;
          test_case "legacy blocker string rejected" `Quick
            test_legacy_last_blocker_string_rejected;
          test_case "repo_cli_identity stays out of runtime meta" `Quick
            test_repo_cli_identity_runtime_meta_rejected;
          test_case "retired persisted runtime fields are scrubbed" `Quick
            test_persisted_retired_runtime_meta_fields_scrubbed;
        ] );
    ]
