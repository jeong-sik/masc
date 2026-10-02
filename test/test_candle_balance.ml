open Alcotest
let at text = match Candle_time.of_rfc3339 text with Ok value -> value | Error detail -> fail detail
let now = at "2026-09-29T00:00:00Z"
let policy : Candle_event.t = {at=now;body=Candle_event.Half_life_set Candle_decay.Off}
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
let state rows = match Candle_balance.of_events ~at:now (policy :: rows) with
  | Ok state -> state | Error error -> fail (Candle_balance.error_to_string error)
let test_cumulative_credit_boundary () =
  let amount = max_int / 1000 in
  let rows = List.init 1000 (fun i -> row (payment (string_of_int i) amount)) in
  let before = state rows in
  check int "all serialized payments accumulated exactly" (amount * 1000)
    (Candle_balance.balance before ~keeper:"keeper");
  let next = payment "overflow" amount in
  (match Candle_balance.credit before ~at:now next with
   | Error (Candle_balance.Balance_overflow "keeper") -> ()
   | Ok _ | Error _ -> fail "cumulative overflow was accepted");
  (match Candle_balance.of_events ~at:now (policy :: rows @ [row next]) with
   | Error (Candle_balance.Balance_overflow "keeper") -> ()
   | Ok _ | Error _ -> fail "an overflowing stored ledger was accepted");
  check int "refused credit preserves the prior balance" (amount * 1000)
    (Candle_balance.balance before ~keeper:"keeper")
let test_one_credit_per_goal () =
  let paid = payment "goal" 1000 in
  let before = state [row paid] in
  (match Candle_balance.credit before ~at:now (payment "goal" 2000) with
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
  let bought = match Candle_balance.purchase credited ~at:now ~keeper:"keeper" ~item ~amount_milli:200 with
    | Ok value -> value | Error error -> fail (Candle_balance.error_to_string error) in
  let supply = Candle_balance.supply bought in
  check string "purchase burns its recorded debit" "200" supply.burned_milli;
  check string "remaining circulation equals wallet" "300" supply.circulating_milli;
  (match Candle_balance.purchase bought ~at:now ~keeper:"keeper" ~item ~amount_milli:1 with
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

let test_historical_half_life_controls_purchase_and_supply () =
  let t0 = now and t1 = at "2026-09-29T01:00:00Z"
  and t2 = at "2026-09-29T02:00:00Z" and t3 = at "2026-09-29T03:00:00Z"
  and t8 = at "2026-09-29T08:00:00Z" in
  let item = match Keeper_portrait_item.of_id "glasses" with Some item -> item | None -> fail "item missing" in
  let rows : Candle_event.t list =
    [ {at=t0;body=Candle_event.Half_life_set Candle_decay.Off}
    ; {at=t0;body=Candle_event.Paid (payment "decay-funded" 1000)}
    ; {at=t1;body=Candle_event.Half_life_set (Candle_decay.Hours 1)}
    ; {at=t2;body=Candle_event.Purchased {keeper="keeper";item;amount_milli=400}}
    ; {at=t3;body=Candle_event.Half_life_set Candle_decay.Off} ] in
  let projected = match Candle_balance.of_events ~at:t8 rows with
    | Ok state -> state | Error error -> fail (Candle_balance.error_to_string error) in
  check int "Off funds start declining only at the recorded Hours boundary" 50
    (Candle_balance.balance projected ~keeper:"keeper");
  check (list string) "decay preserves the purchased accessory" ["glasses"]
    (List.map Keeper_portrait_item.id (Candle_balance.owned projected ~keeper:"keeper"));
  let supply = Candle_balance.supply projected in
  check string "issuance stays a historical fact" "1000" supply.issued_milli;
  check string "stored purchase and derived decay are both burned" "950" supply.burned_milli;
  check string "circulation equals the remaining wallet" "50" supply.circulating_milli;
  let bytes = List.map (fun row -> match Candle_event.to_line row with Ok line -> line | Error detail -> fail detail) rows in
  let decoded = List.map (fun line -> match Candle_event.of_line line with Ok row -> row | Error detail -> fail detail) bytes in
  check bool "replay after restart uses recorded policies and stored debit" true
    (Candle_balance.of_events ~at:t8 decoded = Ok projected)

let test_observation_and_nonmoney_events_do_not_change_decay () =
  let t1 = at "2026-09-29T01:00:00Z" and t2 = at "2026-09-29T02:00:00Z" in
  let rows : Candle_event.t list =
    [ {at=now;body=Candle_event.Half_life_set (Candle_decay.Hours 1)}
    ; {at=now;body=Candle_event.Paid (payment "quiet-wallet" 1000)}
    ; {at=now;body=Candle_event.Paid (payment ~keeper:"other" "active-wallet" 1000)} ] in
  let fold at rows = match Candle_balance.of_events ~at rows with
    | Ok state -> state | Error error -> fail (Candle_balance.error_to_string error) in
  let observed = fold t1 rows in
  check int "first half-life observation" 500 (Candle_balance.balance observed ~keeper:"keeper");
  let later = fold t2 rows in
  let item = match Keeper_portrait_item.of_id "glasses" with Some item -> item | None -> fail "item missing" in
  let with_activity = rows @
    [{Candle_event.at=t1;body=Candle_event.Purchased {keeper="other";item;amount_milli=100}};
     {Candle_event.at=t1;body=Candle_event.Equipped {keeper="keeper";slot=Keeper_portrait_item.slot item;choice=Candle_event.Default}}] in
  check int "unrelated purchase and equipment do not segment this wallet" 250
    (Candle_balance.balance (fold t2 with_activity) ~keeper:"keeper");
  check int "observing never commits a rounding boundary" 250
    (Candle_balance.balance later ~keeper:"keeper");
  check int "earlier projection is immutable" 500 (Candle_balance.balance observed ~keeper:"keeper")

let test_money_requires_policy_and_known_time () =
  let paid = payment "explicit-policy" 1000 in
  (match Candle_balance.of_events ~at:now [row paid] with
   | Error Candle_balance.Missing_half_life -> ()
   | _ -> fail "money with no explicit policy was admitted");
  let historical = [policy;row paid] in
  (match Candle_balance.of_events ~at:(at "2026-09-28T23:59:59Z") historical with
   | Error (Candle_balance.Clock_reversed _) -> ()
   | _ -> fail "a backwards monetary observation invented a balance");
  let current = state [row paid] in
  check int "failed observation does not consume money" 1000
    (Candle_balance.balance current ~keeper:"keeper")

let test_policy_clock_before_first_wallet () =
  let t1 = at "2026-09-29T01:00:00Z" and t2 = at "2026-09-29T02:00:00Z" in
  let hours at : Candle_event.t = {at;body=Candle_event.Half_life_set (Candle_decay.Hours 1)} in
  let payment at : Candle_event.t = {at;body=Candle_event.Paid (payment "first-wallet-clock" 1000)} in
  List.iter (fun (at,rows) -> match Candle_balance.of_events ~at rows with
    | Error (Candle_balance.Clock_reversed _) -> ()
    | _ -> fail "a reversed policy clock was accepted before the first wallet")
    [ t1,[hours t2]
    ; t2,[hours t2;payment t1]
    ; t2,[hours t2;hours t1]
    ; t2,[policy;hours t2;payment t1]
    ];
  match Candle_balance.of_events ~at:t2 [hours t1;payment t1;hours t1] with
  | Error error -> fail (Candle_balance.error_to_string error)
  | Ok state -> check int "equal-time policy and funding retain one half-life interval" 500
      (Candle_balance.balance state ~keeper:"keeper")

let () = run "candle_balance"
  ["ledger credits", [test_case "serialized payments cannot overflow a balance" `Quick test_cumulative_credit_boundary;
    test_case "a Goal is credited once" `Quick test_one_credit_per_goal;
    test_case "deduction and purchases conserve actual currency" `Quick test_supply_tracks_actual_currency;
    test_case "aggregate supply exceeds machine integer without wrapping" `Quick test_supply_above_machine_integer;
    test_case "recorded half-life changes preserve purchases and supply" `Quick test_historical_half_life_controls_purchase_and_supply;
    test_case "observations and other activity do not alter wallet decay" `Quick test_observation_and_nonmoney_events_do_not_change_decay;
    test_case "money requires explicit policy and known time" `Quick test_money_requires_policy_and_known_time;
    test_case "policy chronology is enforced before the first wallet" `Quick test_policy_clock_before_first_wallet]]
