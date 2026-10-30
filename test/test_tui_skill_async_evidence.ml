open Alcotest
module Ledger = Masc.Keeper_skill_activation_ledger
module Action = Masc.Keeper_skill_async_action
module Delivery = Masc.Keeper_skill_async_delivery
module View = Masc.Tui_skill_async_evidence

let require = function Ok value -> value | Error detail -> fail detail
let fields json = Yojson.Safe.Util.to_assoc json
let replace name value json =
  `Assoc (List.map (fun (key, previous) -> key, if key = name then value else previous) (fields json))

let fixture () =
  let json = Yojson.Safe.from_file "fixtures/skill-ledger-async-actions.json" in
  match Ledger.of_projection_yojson json with
  | Ok ledger -> ledger
  | Error error -> fail (Ledger.decode_error_code error)

let selected ledger deliveries actions =
  match Ledger.async_evidence_of_yojson ~expected_trace_id:(Ledger.session_id ledger)
      ~activation:(List.hd (Ledger.activations ledger))
      (`Assoc ["async_result_deliveries", `List (List.map Delivery.to_json deliveries);
               "async_actions", `List (List.map Action.to_json actions)]) with
  | Ok evidence -> View.project evidence
  | Error error -> fail (Ledger.decode_error_code error)

let test_distinct_facts () =
  let ledger = fixture () in
  let deliveries = Ledger.async_result_deliveries ledger and actions = Ledger.async_actions ledger in
  let view = selected ledger deliveries actions in
  check int "physical handoffs" 2 (List.length view.result_deliveries);
  check int "unique physical actions" 3 (List.length view.actions);
  check int "causal links" 3 view.action_link_count;
  List.iter2 (fun expected (group : View.action_group) ->
    check bool "closed outcome and physical identity are unchanged" true
      (Action.same_fact expected group.first)) actions view.actions;
  let empty = selected ledger [] [] in
  check int "an observed activation need not have async handoffs" 0 (List.length empty.result_deliveries);
  check int "empty evidence has no invented action" 0 (List.length empty.actions)

let test_shared_physical_action () =
  let ledger = fixture () in
  let deliveries = Ledger.async_result_deliveries ledger and actions = Ledger.async_actions ledger in
  let extra = List.hd deliveries |> Delivery.to_json
    |> replace "request_id" (`String "another-result")
    |> replace "observed_at" (`String "2026-10-15T12:00:00Z")
    |> Delivery.of_json |> require in
  let link = List.hd actions |> Action.to_json
    |> replace "delivery_sha256" (`String (Delivery.identity extra))
    |> replace "observed_at" (`String "2026-10-15T12:00:01Z")
    |> Action.of_json |> require in
  let view = selected ledger (deliveries @ [extra]) (actions @ [link]) in
  check int "both receipts remain visible" 3 (List.length view.result_deliveries);
  check int "four causal links are not four executions" 4 view.action_link_count;
  check int "one group per physical occurrence" 3 (List.length view.actions);
  let group = List.hd view.actions in
  check bool "the first fact retains its clock" true
    (group.first = List.hd actions);
  check bool "the second receipt link and its clock are retained" true
    (group.additional_links = [link])

let test_distinct_receiving_turn () =
  let ledger = fixture () in
  let deliveries = Ledger.async_result_deliveries ledger and actions = Ledger.async_actions ledger in
  let extra = List.hd deliveries |> Delivery.to_json
    |> replace "physical_turn_ref" (`String "new-physical-trace#74")
    |> Delivery.of_json |> require in
  let action = List.hd actions |> Action.to_json
    |> replace "physical_turn_ref" (`String "new-physical-trace#74")
    |> replace "delivery_sha256" (`String (Delivery.identity extra))
    |> Action.of_json |> require in
  let view = selected ledger (deliveries @ [extra]) (actions @ [action]) in
  check int "same SDK invocation on another physical turn is another action" 4
    (List.length view.actions)

let () = run "retained async Skill detail decisions"
  ["canonical facts", [test_case "closed facts and empty evidence" `Quick test_distinct_facts;
                      test_case "shared physical action retains all links" `Quick test_shared_physical_action;
                      test_case "receiving turn distinguishes executions" `Quick test_distinct_receiving_turn]]
