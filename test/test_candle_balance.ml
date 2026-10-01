open Alcotest
let payment ?(keeper="keeper") ?(deduction_rate=0) ?(overdue_hours=0) goal amount =
  match Candle_payment.make
    ~identity:{goal_id=goal;request_id="request";verification_run_id="verified"}
    ~grade:Candle_grade.Trivial ~total_milli:amount
    ~grade_trace:{run_id="grade";slot_id="slot"}
    ~relations:[{task_id="task";relation=Candle_appraisal.Related;trace={run_id="relation";slot_id="slot"}}]
    ~weights_trace:{run_id="weights";slot_id="slot"}
    ~weight_max:1 ~deduction_rate ~deduction_floor:0 ~overdue_hours
    ~weights:[keeper,1] with
  | Ok value -> value | Error detail -> fail detail
let row payment =
  let at = match Candle_time.of_rfc3339 "2026-09-29T00:00:00Z" with
    | Ok at -> at | Error detail -> fail detail in
  let line = match Candle_event.to_line {at;body=Candle_event.Paid payment} with
    | Ok line -> line | Error detail -> fail detail in
  match Candle_event.of_line line with Ok row -> row | Error detail -> fail detail
let state rows = match Candle_balance.of_events rows with
  | Ok state -> state | Error error -> fail (Candle_balance.error_to_string error)
let test_cumulative_credit_boundary () =
  let amount = max_int / 1000 in
  let rows = List.init 1000 (fun i -> row (payment (string_of_int i) amount)) in
  let before = state rows in
  check int "all serialized payments accumulated exactly" (amount * 1000)
    (Candle_balance.balance before ~keeper:"keeper");
  let next = payment "overflow" amount in
  (match Candle_balance.credit before next with
   | Error (Candle_balance.Balance_overflow "keeper") -> ()
   | Ok _ | Error _ -> fail "cumulative overflow was accepted");
  (match Candle_balance.of_events (rows @ [row next]) with
   | Error (Candle_balance.Balance_overflow "keeper") -> ()
   | Ok _ | Error _ -> fail "an overflowing stored ledger was accepted");
  check int "refused credit preserves the prior balance" (amount * 1000)
    (Candle_balance.balance before ~keeper:"keeper")
let test_one_credit_per_goal () =
  let paid = payment "goal" 1000 in
  let before = state [row paid] in
  (match Candle_balance.credit before (payment "goal" 2000) with
   | Error (Candle_balance.Duplicate_payment "goal") -> ()
   | Ok _ | Error _ -> fail "a repeated Goal payment was accepted");
  check int "duplicate did not credit again" 1000
    (Candle_balance.balance before ~keeper:"keeper");
  check int "unmentioned Keeper has zero credit" 0
    (Candle_balance.balance before ~keeper:"other")
let test_supply_tracks_actual_currency () =
  let paid = payment ~deduction_rate:500 ~overdue_hours:1 "deducted" 1001 in
  let credited = state [row paid] in
  let supply = Candle_balance.supply credited in
  check string "issuance uses actual post-deduction allocation" "500" supply.issued_milli;
  let item = match Keeper_portrait_item.of_id "glasses" with
    | Some item -> item | None -> fail "catalog fixture missing" in
  let bought = match Candle_balance.purchase credited ~keeper:"keeper" ~item ~amount_milli:200 with
    | Ok value -> value | Error error -> fail (Candle_balance.error_to_string error) in
  let supply = Candle_balance.supply bought in
  check string "purchase burns its recorded debit" "200" supply.burned_milli;
  check string "remaining circulation equals wallet" "300" supply.circulating_milli;
  (match Candle_balance.purchase bought ~keeper:"keeper" ~item ~amount_milli:1 with
   | Error (Candle_balance.Already_owned _) -> ()
   | Ok _ | Error _ -> fail "duplicate purchase accepted");
  check bool "refused purchase does not burn currency" true (Candle_balance.supply bought = supply);
  let json = Candle_observation.to_json (Candle_observation.Ready supply) in
  check bool "exact supply wire round trips" true
    (Candle_observation.of_json json = Ok (Candle_observation.Ready supply));
  let inconsistent = `Assoc ["status", `String "ready";
    "issued_milli", `String "500"; "burned_milli", `String "200";
    "circulating_milli", `String "301"] in
  (match Candle_observation.of_json inconsistent with
   | Error _ -> () | Ok _ -> fail "inconsistent currency supply accepted");
  List.iter (fun amount -> match Candle_observation.amount_of_json (`String amount) with
    | Error _ -> () | Ok _ -> fail "noncanonical amount accepted")
    ["";"01";"-1";"1.0";"1e3";" 1"]

let test_supply_above_machine_integer () =
  let amount = max_int / 1000 in
  let rows = List.init 1001 (fun i ->
    row (payment ~keeper:(if i < 1000 then "keeper" else "other")
      ("supply-" ^ string_of_int i) amount)) in
  let supply = Candle_balance.supply (state rows) in
  let expected = Int64.(to_string (mul (of_int amount) 1001L)) in
  check string "valid separate wallets can issue above max_int" expected supply.issued_milli;
  check string "all issuance remains circulating" expected supply.circulating_milli;
  check string "no purchase means no burn" "0" supply.burned_milli;
  check bool "wire preserves above-machine amount" true
    (Candle_observation.of_json (Candle_observation.to_json (Candle_observation.Ready supply))
      = Ok (Candle_observation.Ready supply))

let () = run "candle_balance"
  ["ledger credits", [test_case "serialized payments cannot overflow a balance" `Quick test_cumulative_credit_boundary;
    test_case "a Goal is credited once" `Quick test_one_credit_per_goal;
    test_case "deduction and purchases conserve actual currency" `Quick test_supply_tracks_actual_currency;
    test_case "aggregate supply exceeds machine integer without wrapping" `Quick test_supply_above_machine_integer]]
