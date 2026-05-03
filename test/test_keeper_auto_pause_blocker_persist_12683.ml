(** #12683 — pin that auto-pause paths write [last_blocker] and
    [last_blocker_class] into keeper_meta so the blocker survives
    supervisor unregister/restart.

    Two structural facts this test pins:

    1. [blocker_class_to_string] maps [Turn_timeout] and
       [Oas_timeout_budget] to canonical labels that the dashboard
       and [paused_meta_requires_reconcile_recovery] can parse back.

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

let test_oas_timeout_budget_blocker_class_roundtrip () =
  let cls = KT.Oas_timeout_budget in
  let label = KT.blocker_class_to_string cls in
  check bool "label non-empty" true (String.length label > 0);
  match MC.blocker_class_of_serialized_string label with
  | Some _ -> ()
  | None -> fail "Oas_timeout_budget label did not parse back"

let test_blocker_class_labels_are_distinct () =
  let tt = KT.blocker_class_to_string KT.Turn_timeout in
  let ot = KT.blocker_class_to_string KT.Oas_timeout_budget in
  check bool "Turn_timeout <> Oas_timeout_budget" true (tt <> ot)

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
  let blocker_text = KT.blocker_class_to_string KT.Oas_timeout_budget in
  let paused_meta = { meta with
    paused = true;
    auto_resume_after_sec = Some 3600.0;
    runtime = { meta.runtime with
      last_blocker = blocker_text;
      last_blocker_class = Some KT.Oas_timeout_budget;
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
  check string "last_blocker preserved"
    blocker_text reparsed.runtime.last_blocker;
  check bool "last_blocker_class is Some"
    true (Option.is_some reparsed.runtime.last_blocker_class)

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
      last_blocker = blocker_text;
      last_blocker_class = Some KT.Turn_timeout;
    };
  } in
  let json = KT.meta_to_json paused_meta in
  let reparsed = match KT.meta_of_json json with
    | Ok m -> m
    | Error err -> fail ("roundtrip: " ^ err)
  in
  check string "last_blocker"
    blocker_text reparsed.runtime.last_blocker;
  check bool "last_blocker_class is Some"
    true (Option.is_some reparsed.runtime.last_blocker_class)

let () =
  run "keeper_auto_pause_blocker_persist_12683"
    [
      ( "blocker_class labels",
        [
          test_case "Turn_timeout roundtrip" `Quick
            test_turn_timeout_blocker_class_roundtrip;
          test_case "Oas_timeout_budget roundtrip" `Quick
            test_oas_timeout_budget_blocker_class_roundtrip;
          test_case "labels are distinct" `Quick
            test_blocker_class_labels_are_distinct;
        ] );
      ( "meta JSON roundtrip",
        [
          test_case "OAS budget blocker survives serialization" `Quick
            test_meta_json_roundtrip_with_auto_pause_blocker;
          test_case "stale storm blocker survives serialization" `Quick
            test_meta_json_roundtrip_with_stale_storm_blocker;
        ] );
    ]
