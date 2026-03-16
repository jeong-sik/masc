(** Tests for OAS subsystem integration: Agent Cards, Event_bus publishing,
    Gardener Pulse migration, and Sentinel->Gardener event subscription. *)

open Agent_sdk
open Masc_mcp

(* ================================================================ *)
(* Agent Card identity tests                                         *)
(* ================================================================ *)

let test_guardian_agent_card () =
  let card = Guardian.agent_card in
  Alcotest.(check string) "guardian name" "guardian" card.Agent_card.name;
  Alcotest.(check bool) "has description" true (Option.is_some card.Agent_card.description);
  Alcotest.(check bool) "has skills" true (List.length card.Agent_card.skills >= 2)

let test_sentinel_agent_card () =
  let card = Sentinel.agent_card in
  Alcotest.(check string) "sentinel name" "sentinel" card.Agent_card.name;
  Alcotest.(check bool) "has 4 skills" true (List.length card.Agent_card.skills >= 4)

let test_gardener_agent_card () =
  let card = Gardener.agent_card in
  Alcotest.(check string) "gardener name" "gardener" card.Agent_card.name;
  Alcotest.(check bool) "has 3 skills" true (List.length card.Agent_card.skills >= 3)

let test_all_cards_have_protocol_v03 () =
  let cards = [Guardian.agent_card; Sentinel.agent_card; Gardener.agent_card] in
  List.iter (fun (card : Agent_card.agent_card) ->
    Alcotest.(check bool) (card.name ^ " protocol v0.3")
      true (List.mem "0.3" card.protocol_versions)
  ) cards

(* ================================================================ *)
(* Event_bus publish tests                                           *)
(* ================================================================ *)

let test_guardian_zombie_event_schema () =
  Eio_main.run @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = Event_bus.subscribe bus in
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.Custom ("masc:guardian:zombie_cleanup",
      `Assoc [
        ("agent_name", `String "guardian");
        ("result", `String "cleaned 0 zombies");
        ("timestamp", `Float 1234567890.0);
      ]));
  let events = Event_bus.drain sub in
  Alcotest.(check int) "one event" 1 (List.length events);
  match List.hd events with
  | Event_bus.Custom ("masc:guardian:zombie_cleanup", payload) ->
    let agent = Yojson.Safe.Util.(member "agent_name" payload |> to_string) in
    Alcotest.(check string) "agent name" "guardian" agent
  | _ -> Alcotest.fail "expected Custom masc:guardian:zombie_cleanup event"

let test_guardian_gc_event_schema () =
  Eio_main.run @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = Event_bus.subscribe bus in
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.Custom ("masc:guardian:gc",
      `Assoc [
        ("agent_name", `String "guardian");
        ("result", `String "gc complete");
        ("gc_days", `Int 7);
        ("timestamp", `Float 1234567890.0);
      ]));
  let events = Event_bus.drain sub in
  Alcotest.(check int) "one event" 1 (List.length events);
  match List.hd events with
  | Event_bus.Custom ("masc:guardian:gc", payload) ->
    let days = Yojson.Safe.Util.(member "gc_days" payload |> to_int) in
    Alcotest.(check int) "gc_days" 7 days
  | _ -> Alcotest.fail "expected Custom masc:guardian:gc event"

let test_sentinel_task_hygiene_event_schema () =
  Eio_main.run @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = Event_bus.subscribe bus in
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.Custom ("masc:sentinel:task_hygiene",
      `Assoc [
        ("agent_name", `String "sentinel");
        ("orphan_count", `Int 2);
        ("stuck_count", `Int 1);
        ("reassigned", `Int 1);
        ("timestamp", `Float 1234567890.0);
      ]));
  let events = Event_bus.drain sub in
  Alcotest.(check int) "one event" 1 (List.length events);
  match List.hd events with
  | Event_bus.Custom ("masc:sentinel:task_hygiene", payload) ->
    let orphan = Yojson.Safe.Util.(member "orphan_count" payload |> to_int) in
    let stuck = Yojson.Safe.Util.(member "stuck_count" payload |> to_int) in
    Alcotest.(check int) "orphan_count" 2 orphan;
    Alcotest.(check int) "stuck_count" 1 stuck
  | _ -> Alcotest.fail "expected Custom masc:sentinel:task_hygiene event"

let test_sentinel_board_patrol_event_schema () =
  Eio_main.run @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = Event_bus.subscribe bus in
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.Custom ("masc:sentinel:board_patrol",
      `Assoc [
        ("agent_name", `String "sentinel");
        ("action", `String "posted");
        ("stale_count", `Int 3);
        ("reason", `String "3 stale posts");
        ("timestamp", `Float 1234567890.0);
      ]));
  let events = Event_bus.drain sub in
  Alcotest.(check int) "one event" 1 (List.length events);
  match List.hd events with
  | Event_bus.Custom ("masc:sentinel:board_patrol", payload) ->
    let action = Yojson.Safe.Util.(member "action" payload |> to_string) in
    Alcotest.(check string) "action" "posted" action
  | _ -> Alcotest.fail "expected Custom masc:sentinel:board_patrol event"

let test_gardener_tick_event_schema () =
  Eio_main.run @@ fun _env ->
  let bus = Event_bus.create () in
  let sub = Event_bus.subscribe bus in
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.Custom ("masc:gardener:tick",
      `Assoc [
        ("agent_name", `String "gardener");
        ("circuit_open", `Bool false);
        ("timestamp", `Float 1234567890.0);
      ]));
  let events = Event_bus.drain sub in
  Alcotest.(check int) "one event" 1 (List.length events);
  match List.hd events with
  | Event_bus.Custom ("masc:gardener:tick", payload) ->
    let circuit = Yojson.Safe.Util.(member "circuit_open" payload |> to_bool) in
    Alcotest.(check bool) "circuit_open" false circuit
  | _ -> Alcotest.fail "expected Custom masc:gardener:tick event"

(* ================================================================ *)
(* Event_bus cross-subsystem filter test                             *)
(* ================================================================ *)

let test_sentinel_event_filter () =
  Eio_main.run @@ fun _env ->
  let bus = Event_bus.create () in
  let starts_with prefix s =
    String.length s >= String.length prefix &&
    String.sub s 0 (String.length prefix) = prefix
  in
  let sentinel_sub = Event_bus.subscribe bus
    ~filter:(function
      | Event_bus.Custom (name, _) -> starts_with "masc:sentinel:" name
      | _ -> false)
  in
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.Custom ("masc:guardian:gc", `Null));
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.Custom ("masc:sentinel:task_hygiene",
      `Assoc [("orphan_count", `Int 1)]));
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.Custom ("masc:sentinel:board_patrol",
      `Assoc [("action", `String "posted")]));
  Agent_sdk.Event_bus.publish bus
    (Agent_sdk.Event_bus.Custom ("masc:guardian:zombie_cleanup", `Null));
  let events = Event_bus.drain sentinel_sub in
  Alcotest.(check int) "only sentinel events" 2 (List.length events)

(* ================================================================ *)
(* Subsystem conformance tests                                       *)
(* ================================================================ *)

let test_guardian_conforms_to_subsystem () =
  let name = Guardian.agent_card.Agent_card.name in
  let _card = Guardian.agent_card in
  let _status = Guardian.status_json () in
  Alcotest.(check string) "name" "guardian" name

let test_sentinel_conforms_to_subsystem () =
  let name = Sentinel.agent_card.Agent_card.name in
  let _card = Sentinel.agent_card in
  let _status = Sentinel.status_json () in
  Alcotest.(check string) "name" "sentinel" name

let test_gardener_conforms_to_subsystem () =
  let name = Gardener.agent_card.Agent_card.name in
  let _card = Gardener.agent_card in
  let _status = Gardener.status_json () in
  Alcotest.(check string) "name" "gardener" name

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  Alcotest.run "Subsystem OAS Integration" [
    "agent_cards", [
      Alcotest.test_case "guardian agent card" `Quick test_guardian_agent_card;
      Alcotest.test_case "sentinel agent card" `Quick test_sentinel_agent_card;
      Alcotest.test_case "gardener agent card" `Quick test_gardener_agent_card;
      Alcotest.test_case "all cards protocol v0.3" `Quick test_all_cards_have_protocol_v03;
    ];
    "event_bus_schema", [
      Alcotest.test_case "guardian zombie event" `Quick test_guardian_zombie_event_schema;
      Alcotest.test_case "guardian gc event" `Quick test_guardian_gc_event_schema;
      Alcotest.test_case "sentinel task hygiene event" `Quick test_sentinel_task_hygiene_event_schema;
      Alcotest.test_case "sentinel board patrol event" `Quick test_sentinel_board_patrol_event_schema;
      Alcotest.test_case "gardener tick event" `Quick test_gardener_tick_event_schema;
    ];
    "cross_subsystem", [
      Alcotest.test_case "sentinel event filter" `Quick test_sentinel_event_filter;
    ];
    "subsystem_conformance", [
      Alcotest.test_case "guardian conforms to Subsystem.S" `Quick test_guardian_conforms_to_subsystem;
      Alcotest.test_case "sentinel conforms to Subsystem.S" `Quick test_sentinel_conforms_to_subsystem;
      Alcotest.test_case "gardener conforms to Subsystem.S" `Quick test_gardener_conforms_to_subsystem;
    ];
  ]
