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
    | Error (Cost.Invalid_cost | Cost.Cost_overflow | Cost.Evidence_regressed
            | Cost.History_rewritten | Cost.Evidence_inconsistent) ->
      fail "wrong overflow evidence"
  in
  grow (fold [Cost.Priced 0.])

let decode json = match Cost.of_json json with
  | Ok value -> value | Error detail -> fail detail

let roundtrip state =
  let json = Cost.to_json state in
  let after = decode (Yojson.Safe.from_string (Yojson.Safe.to_string json)) in
  check bool "durable cost and coverage survive" true (state = after)

let scalar_unknown () =
  List.iter (fun json ->
    let state = decode json in
    has_knowledge Cost.Unresolved state;
    check int "no fabricated priced count" 0 state.priced_readings;
    check int "no fabricated unpriced count" 0 state.unpriced_readings;
    check bool "ordinary save preserves scalar arm" true
      (Cost.to_json state = `Float state.known_cost_usd);
    roundtrip state) [`Int 0; `Float 0.; `Float 12.5]

let explicit_coverage_wire () =
  List.iter (fun state ->
    check bool "explicit coverage is an object" true
      (match Cost.to_json state with `Assoc _ -> true | _ -> false);
    roundtrip state)
    [Cost.empty; fold [Cost.Priced 0.]; fold [Cost.Price_not_reported];
     fold [Cost.Priced 2.; Cost.Price_not_reported];
     fold [Cost.Usage_unresolved; Cost.Attempt_unobserved]]

let history_after_first_reading () =
  let baseline = decode (`Float 12.) in
  let after = get (Cost.observe baseline (Cost.Priced 0.)) in
  has_knowledge Cost.Unresolved after;
  check bool "unknown prefix remains" true (after.history = Cost.Unobserved);
  check int "new zero is actually priced" 1 after.priced_readings;
  roundtrip after;
  let delta = get (Cost.difference ~before:baseline ~after) in
  let newer = get (Cost.observe baseline Cost.Price_not_reported) in
  let committed = get (Cost.add newer delta) in
  check bool "concurrent commit retains unknown prefix" true
    (committed.history = Cost.Unobserved);
  check int "newer reading is retained" 1 committed.unpriced_readings;
  roundtrip committed

let reject_malformed_wire () =
  let fields = match Cost.to_json Cost.empty with `Assoc fields -> fields | _ -> fail "object" in
  let replace key value = `Assoc (List.map (fun (name, old) -> name, if name=key then value else old) fields) in
  let bad =
    [`Null; `Bool false; `String "0"; `Float Float.nan; `Float Float.infinity;
     `Float (-1.); `Assoc (List.remove_assoc "history" fields);
     `Assoc (("history", `String "complete")::fields);
     `Assoc (("extra", `Null)::fields);
     replace "history" (`String "unknown");
     replace "priced_readings" (`Int (-1));
     replace "unpriced_readings" (`Float 1.);
     replace "unresolved_readings" (`String "1");
     replace "unobserved_attempts" `Null;
     replace "known_cost_usd" (`Float 1.)]
  in
  List.iter (fun json -> check bool "damaged coverage is refused" true
    (Result.is_error (Cost.of_json json))) bad

let reject_inconsistent_delta () =
  let before = fold [Cost.Priced 2.] in
  let after = fold [Cost.Priced 3.] in
  error Cost.Evidence_inconsistent (Cost.difference ~before ~after)

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
     test_case "coverage counts cannot wrap" `Quick count_overflow];
   "durable coverage",
    [test_case "numeric zero is unknown history" `Quick scalar_unknown;
     test_case "complete empty and priced zero remain objects" `Quick explicit_coverage_wire;
     test_case "new readings and concurrent delta preserve unknown prefix" `Quick history_after_first_reading;
     test_case "damaged coverage cannot salvage a sum" `Quick reject_malformed_wire;
     test_case "different lineages cannot invent priced delta" `Quick reject_inconsistent_delta]]
