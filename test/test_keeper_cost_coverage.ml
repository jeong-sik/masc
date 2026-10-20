open Alcotest
module Cost = Keeper_cost_coverage

let get = function Ok value -> value | Error _ -> fail "cost observation rejected"
let fold observations = List.fold_left (fun state row -> get (Cost.observe state row)) Cost.empty observations
let has_knowledge expected state = check bool "pricing knowledge" true (Cost.knowledge state = expected)
let error expected result = check bool "typed refusal" true (result = Error expected)

let zero_and_absence () =
  has_knowledge Cost.No_observations Cost.empty;
  let zero = fold [Cost.Priced 0.] in
  let unpriced = fold [Cost.Price_not_reported] in
  check (float 0.) "reported zero" 0. zero.known_cost_usd;
  check (float 0.) "sum has no reported price" 0. unpriced.known_cost_usd;
  has_knowledge Cost.Fully_priced zero;
  has_knowledge Cost.No_reported_prices unpriced

let mixed_readings () =
  let state = fold [Cost.Priced 1.25; Cost.Price_not_reported; Cost.Priced 0.] in
  check (float 0.) "known part survives missing price" 1.25 state.known_cost_usd;
  check int "zero is a priced reading" 2 state.priced_readings;
  check int "missing price retained" 1 state.unpriced_readings;
  has_knowledge Cost.Partly_priced state

let unresolved_usage () =
  let state = fold [Cost.Priced 2.; Cost.Usage_unresolved] in
  check int "unresolved is not an explicit missing price" 0 state.unpriced_readings;
  check int "unresolved reading preserved" 1 state.unresolved_readings;
  has_knowledge Cost.Unresolved state

let empty_attempt () =
  let state = fold [Cost.Attempt_unobserved] in
  check int "no fabricated reading" 0 state.priced_readings;
  check int "attempt remains unobserved" 1 state.unobserved_attempts;
  has_knowledge Cost.Unresolved state

let historical_coverage () =
  List.iter (fun amount ->
    let baseline = get (Cost.unobserved_history ~known_cost_usd:amount) in
    has_knowledge Cost.Unresolved baseline;
    let state = get (Cost.observe baseline (Cost.Priced 3.)) in
    check (float 0.) "retained reported history" (amount +. 3.) state.known_cost_usd;
    check int "history did not invent priced readings" 1 state.priced_readings;
    has_knowledge Cost.Unresolved state) [0.; 12.]

let concurrent_snapshot_deltas () =
  let baseline = get (Cost.unobserved_history ~known_cost_usd:12.) in
  let first = get (Cost.add baseline (fold [Cost.Priced 2.; Cost.Price_not_reported])) in
  let second = get (Cost.observe baseline (Cost.Priced 3.)) in
  let first_delta = get (Cost.difference ~before:baseline ~after:first) in
  let second_delta = get (Cost.difference ~before:baseline ~after:second) in
  let combined = get (Cost.add (get (Cost.add baseline first_delta)) second_delta) in
  check (float 0.) "both snapshot deltas retained" 17. combined.known_cost_usd;
  check int "both priced readings retained" 2 combined.priced_readings;
  check int "missing price survived newer commit" 1 combined.unpriced_readings;
  has_knowledge Cost.Unresolved combined;
  let unchanged = get (Cost.difference ~before:combined ~after:combined) in
  let same = get (Cost.add combined unchanged) in
  check bool "unchanged snapshot adds no facts" true (same = combined)

let refuse_regression () =
  let priced = fold [Cost.Priced 2.] in
  error Cost.Evidence_regressed (Cost.difference ~before:priced ~after:Cost.empty);
  let unpriced = fold [Cost.Price_not_reported] in
  error Cost.Evidence_regressed (Cost.difference ~before:unpriced ~after:Cost.empty);
  let unknown = get (Cost.unobserved_history ~known_cost_usd:0.) in
  error Cost.History_rewritten (Cost.difference ~before:unknown ~after:Cost.empty)

let invalid_amounts () =
  List.iter (fun amount ->
    error Cost.Invalid_cost (Cost.observe Cost.empty (Cost.Priced amount));
    error Cost.Invalid_cost (Cost.unobserved_history ~known_cost_usd:amount))
    [-1.; Float.infinity; Float.neg_infinity; Float.nan];
  let maximum = fold [Cost.Priced Float.max_float] in
  error Cost.Cost_overflow (Cost.add maximum maximum)

let count_overflow () =
  let rec grow state =
    match Cost.add state state with
    | Ok next -> grow next
    | Error Cost.Count_overflow -> ()
    | Error (Cost.Invalid_cost | Cost.Cost_overflow | Cost.Evidence_regressed | Cost.History_rewritten) ->
      fail "wrong overflow evidence"
  in
  grow (fold [Cost.Priced 0.])

let () = run "Keeper cost coverage"
  ["pricing observations",
    [test_case "reported zero and missing price differ" `Quick zero_and_absence;
     test_case "mixed readings retain known part and coverage" `Quick mixed_readings;
     test_case "unresolved usage is not explicit missing price" `Quick unresolved_usage;
     test_case "empty attempt does not establish free usage" `Quick empty_attempt;
     test_case "unknown historical coverage stays unknown" `Quick historical_coverage;
     test_case "stale snapshot deltas preserve concurrent coverage" `Quick concurrent_snapshot_deltas;
     test_case "regression cannot erase evidence" `Quick refuse_regression;
     test_case "invalid or overflowing amounts are refused" `Quick invalid_amounts;
     test_case "coverage counts cannot wrap" `Quick count_overflow]]
