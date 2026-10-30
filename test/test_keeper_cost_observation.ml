open Alcotest
open Masc
module Cost = Keeper_cost_coverage
module Spend = Keeper_turn_spend
module Owner = Keeper_owner_reducer

let get = function Ok value -> value | Error _ -> fail "unexpected typed refusal"
let meta amount =
  let json = Masc_test_deps.current_meta_json_fixture ~name:"cost-observation" () in
  let fields = match json with `Assoc fields -> fields | _ -> fail "object fixture" in
  get (Keeper_meta_json_parse.meta_of_json
    (`Assoc (("total_cost_usd", `Float amount) :: List.remove_assoc "total_cost_usd" fields)))
let cost (meta : Keeper_meta_contract.keeper_meta) = meta.runtime.usage.total_cost_usd
let set_cost meta total_cost_usd =
  Keeper_meta_contract.map_usage (fun usage -> {usage with total_cost_usd}) meta
let saved meta = get (Keeper_meta_json_parse.meta_of_json (Keeper_meta_json.meta_to_json meta))

let ordinary_save_preserves_unknown () =
  List.iter (fun amount ->
    let before = meta amount in
    let owner = get (Owner.create ~keeper_name:before.name (Some before)) in
    let paused = get (Owner.apply_meta owner (Owner.Pause
      {reason=Keeper_latched_reason.Operator_paused
          {operator_actor=Keeper_latched_reason.Grpc_directive};updated_at="paused"})) in
    let persisted = saved (Option.get paused.projection.meta) in
    check bool "pause/save preserves all historical cost facts" true (cost before = cost persisted);
    check bool "zero never asserts historical pricing" true (Cost.knowledge (cost persisted) = Cost.Unresolved);
    let json = Keeper_meta_json.meta_to_json persisted in
    match Tui_decode.decode_keeper json with
    | Error detail -> fail detail
    | Ok keeper ->
      check bool "roster decoder retains the same cost authority" true
        ((Option.get keeper.k_activity).k_total_cost_usd = cost before)) [0.;12.]

let started = Spend.start_attempt Spend.empty ~routing_run_id:"cost-run" ~runtime_id:"core" ~lane_attempt_index:0
let response state id usage = get (Spend.observe_agent_core_response state
  ~response_id:id ~ordinal:1 ~model:"cost-fixture" usage)
let capture state =
  let attempts = Spend.attempts state in
  let resolved, _ = Spend.resolve ~cursor:None ~observed_at:1. attempts in
  get (Spend.cost_coverage ~resolved attempts)

let actual_readings_and_empty_attempts () =
  let usage price = {Agent_core.Types.zero_api_usage with cost_usd=price} in
  let zero = capture (response started "zero" (Some (usage (Some 0.)))) in
  check bool "real zero is fully priced" true (Cost.knowledge zero = Cost.Fully_priced);
  let unpriced = capture (response started "unpriced" (Some (usage None))) in
  check bool "real absent price differs" true (Cost.knowledge unpriced = Cost.No_reported_prices);
  let unknown = capture (response started "unresolved" None) in
  check int "response without usage is unresolved" 1 unknown.unresolved_readings;
  let none = capture Spend.empty and empty = capture started in
  check bool "no attempt has no observations" true (Cost.knowledge none = Cost.No_observations);
  check int "started empty attempt is retained" 1 empty.unobserved_attempts;
  let losing = response started "loser" (Some (usage None)) in
  let winner = Spend.start_attempt losing ~routing_run_id:"cost-run" ~runtime_id:"other" ~lane_attempt_index:1 in
  let mixed = capture (response winner "winner" (Some (usage (Some 2.)))) in
  check (float 0.) "winning reported amount" 2. mixed.known_cost_usd;
  check int "losing absence remains" 1 mixed.unpriced_readings;
  check int "winner counted once" 1 mixed.priced_readings

let unavailable_price_baseline_is_unresolved () =
  let sample : Keeper_usage_resolution.sample =
    {input_tokens=10;output_tokens=0;cache_creation_input_tokens=0;
     cache_read_input_tokens=0;cost_usd=None} in
  let cursor : Keeper_usage_resolution.cursor =
    {runtime_id="client";conversation_id="conversation";cumulative=sample} in
  let report : Keeper_client_usage_report.t =
    {official_turn=1;response_id="next";model="fixture";conversation_id="conversation";
     position=Keeper_usage_resolution.Resumed;usage_scope=Runtime_usage_scope.Conversation_cumulative;
     count=Keeper_client_usage_report.Running_count
       {Agent_core.Types.zero_api_usage with input_tokens=20;cost_usd=Some 2.};vendor_total_tokens=None} in
  let started = Spend.start_attempt Spend.empty ~routing_run_id:"run" ~runtime_id:"client" ~lane_attempt_index:0 in
  let attempts = Spend.attempts (get (Spend.observe_client_report started report)) in
  let resolved, _ = Spend.resolve ~cursor:(Some cursor) ~observed_at:2. attempts in
  let captured = get (Spend.cost_coverage ~resolved attempts) in
  check int "provider did price; missing baseline is not unpriced" 0 captured.unpriced_readings;
  check int "unknown cost delta retained" 1 captured.unresolved_readings

let stale_owner_commit_retains_coverage () =
  let before = meta 12. in
  let after_a = set_cost before (get (Cost.observe (cost before) (Cost.Priced 2.))) in
  let after_b = set_cost before (get (Cost.observe (cost before) Cost.Price_not_reported)) in
  let a = get (Owner.turn_runtime_delta_of_snapshots ~before ~after:after_a) in
  let b = get (Owner.turn_runtime_delta_of_snapshots ~before ~after:after_b) in
  let owner = get (Owner.create ~keeper_name:before.name (Some before)) in
  let first = get (Owner.apply_meta owner (Owner.Commit_turn_runtime a)) in
  let second = get (Owner.apply_meta first.state (Owner.Commit_turn_runtime b)) in
  let stored = saved (Option.get second.projection.meta) in
  let result = cost stored in
  check (float 0.) "stale commit retains priced amount" 14. result.known_cost_usd;
  check int "first commit priced count" 1 result.priced_readings;
  check int "second commit unpriced count" 1 result.unpriced_readings;
  check bool "no erasure of historical uncertainty" true (result.history = Cost.Unobserved)

let malformed_meta_cannot_salvage_amount () =
  let meta = meta 12. in
  let json = Keeper_meta_json.meta_to_json meta in
  let fields = match json with `Assoc fields -> fields | _ -> fail "object" in
  let malformed = `Assoc ["known_cost_usd",`Float 12.] in
  check bool "damaged nested coverage is an explicit error" true
    (Result.is_error (Keeper_meta_json_parse.meta_of_json
      (`Assoc (("total_cost_usd",malformed)::List.remove_assoc "total_cost_usd" fields))))

let () = run "Keeper cost observation"
  ["production cost authority",
   [test_case "ordinary save and roster preserve unknown history" `Quick ordinary_save_preserves_unknown;
    test_case "actual readings and started attempts preserve price coverage" `Quick actual_readings_and_empty_attempts;
    test_case "unpriced baseline does not erase a reported price" `Quick unavailable_price_baseline_is_unresolved;
    test_case "actual Owner stale commits add cost and coverage together" `Quick stale_owner_commit_retains_coverage;
    test_case "damaged meta cannot salvage a cost sum" `Quick malformed_meta_cannot_salvage_amount]]
