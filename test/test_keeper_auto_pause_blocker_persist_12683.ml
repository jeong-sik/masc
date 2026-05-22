(** #12683 — pin that auto-pause paths write [last_blocker] and
    [last_blocker_class] into keeper_meta so the blocker survives
    supervisor unregister/restart.

    Two structural facts this test pins:

    1. [blocker_class_of_string] maps legacy ["oas_timeout_budget"]
       to [Turn_timeout] so dashboard/meta round-trips do not resurrect
       timeout-budget as a distinct blocker class.

    2. A meta JSON written with [last_blocker] and [last_blocker_class]
       round-trips through serialization/deserialization without loss,
       so the blocker survives server restart. *)

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

let test_oas_timeout_budget_blocker_class_collapses_to_turn_timeout () =
  let cls = KT.Turn_timeout in
  let label = KT.blocker_class_to_string cls in
  check string "label" "turn_timeout" label;
  match MC.blocker_class_of_serialized_string label with
  | Some MC.Turn_timeout -> ()
  | Some _ -> fail "legacy timeout-budget label parsed as wrong class"
  | None -> fail "legacy timeout-budget label did not parse back"

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

let test_timeout_blocker_class_labels_collapse () =
  let tt = KT.blocker_class_to_string KT.Turn_timeout in
  let ot = KT.blocker_class_to_string KT.Turn_timeout in
  let fb = KT.blocker_class_to_string KT.Stale_fleet_batch in
  check bool "Turn_timeout = Oas_timeout_budget alias" true (tt = ot);
  check bool "Stale_fleet_batch distinct" true (fb <> tt && fb <> ot)

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

let () =
  run "keeper_auto_pause_blocker_persist_12683"
    [
      ( "blocker_class labels",
        [
          test_case "Turn_timeout roundtrip" `Quick
            test_turn_timeout_blocker_class_roundtrip;
          test_case "Oas_timeout_budget collapses to Turn_timeout" `Quick
            test_oas_timeout_budget_blocker_class_collapses_to_turn_timeout;
          test_case "Stale_fleet_batch roundtrip" `Quick
            test_stale_fleet_batch_blocker_class_roundtrip;
          test_case "Capacity_backpressure roundtrip" `Quick
            test_capacity_backpressure_blocker_class_roundtrip;
          test_case "timeout labels collapse" `Quick
            test_timeout_blocker_class_labels_collapse;
        ] );
      ( "meta JSON roundtrip",
        [
          test_case "OAS budget blocker survives serialization" `Quick
            test_meta_json_roundtrip_with_auto_pause_blocker;
          test_case "stale storm blocker survives serialization" `Quick
            test_meta_json_roundtrip_with_stale_storm_blocker;
        ] );
    ]
