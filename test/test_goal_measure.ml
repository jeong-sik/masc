(* Goal_measure: the constructors keep the invariants, the JSON readers go
   through the constructors, and only same-shaped values pair. *)

module M = Goal_measure

let ok what = function
  | Ok value -> value
  | Error reason -> Alcotest.failf "%s: %s" what reason

let refused what = function
  | Ok _ -> Alcotest.failf "%s: expected a refusal" what
  | Error _ -> ()

let label text = ok text (M.make_label text)
let floors = M.count ~noun:(label "층") ~total:(ok "14" (M.make_count 14))
let latency =
  M.quantity ~unit:(label "ms") ~direction:M.At_most
    ~target:(ok "100" (M.make_finite 100.))
let hit_rate =
  M.quantity ~unit:(label "%") ~direction:M.At_least
    ~target:(ok "90" (M.make_finite 90.))
let first_run = M.done_when ~condition:(label "TUI 가 첫 실행에서 키퍼 목록을 그린다")

let test_constructors_refuse_what_the_types_rule_out () =
  refused "blank label" (M.make_label "  ");
  refused "two-line label" (M.make_label "ms\nper call");
  refused "zero count" (M.make_count 0);
  refused "negative count" (M.make_count (-3));
  refused "nan" (M.make_finite Float.nan);
  refused "infinity" (M.make_finite Float.infinity);
  refused "negative counted" (M.counted (-1));
  ignore (ok "zero counted" (M.counted 0))

let reach_of measure observed =
  match M.pair measure observed with
  | Ok paired -> M.reach paired
  | Error mismatch -> Alcotest.failf "pair: %s" (M.mismatch_to_string mismatch)

let reach_name = function M.Reached -> "reached" | M.Short_of -> "short of"
let check_reach what expected measure observed =
  Alcotest.(check string) what (reach_name expected) (reach_name (reach_of measure observed))

let counted n = ok "counted" (M.counted n)
let quantified v = M.quantified (ok "finite" (M.make_finite v))

let test_reach_follows_the_shape () =
  check_reach "1 of 14 floors" M.Short_of floors (counted 1);
  check_reach "14 of 14 floors" M.Reached floors (counted 14);
  check_reach "140 ms against at most 100" M.Short_of latency (quantified 140.);
  check_reach "the limit itself is allowed" M.Reached latency (quantified 100.);
  check_reach "92 % against at least 90" M.Reached hit_rate (quantified 92.);
  check_reach "89.5 % against at least 90" M.Short_of hit_rate (quantified 89.5);
  check_reach "condition held" M.Reached first_run (M.decided true);
  check_reach "condition did not hold" M.Short_of first_run (M.decided false)

let mismatch_name = function
  | Ok _ -> "paired"
  | Error M.Shape_differs -> "shape differs"
  | Error (M.Count_over_total _) -> "count over total"

let test_only_same_shapes_pair () =
  let check what expected measure observed =
    Alcotest.(check string) what expected (mismatch_name (M.pair measure observed))
  in
  check "a quantity for a count" "shape differs" floors (quantified 1.);
  check "a decision for a quantity" "shape differs" latency (M.decided true);
  check "a count for a condition" "shape differs" first_run (counted 1);
  check "15 of 14" "count over total" floors (counted 15)

let roundtrip measure =
  match M.of_yojson (M.to_yojson measure) with
  | Ok back -> Alcotest.(check bool) "measure survives JSON" true (M.equal measure back)
  | Error reason -> Alcotest.failf "measure roundtrip: %s" reason

let observed_roundtrip observed =
  match M.observed_of_yojson (M.observed_to_yojson observed) with
  | Ok back ->
    Alcotest.(check bool) "observed survives JSON" true (M.observed_equal observed back)
  | Error reason -> Alcotest.failf "observed roundtrip: %s" reason

let test_json_roundtrips () =
  List.iter roundtrip [ floors; latency; hit_rate; first_run ];
  List.iter observed_roundtrip [ counted 0; quantified 140.; M.decided false ]

let parse text = M.of_yojson (Yojson.Safe.from_string text)
let parse_observed text = M.observed_of_yojson (Yojson.Safe.from_string text)

let test_json_reads_strictly () =
  ignore (ok "integer target" (parse {|{"kind":"quantity","unit":"ms","direction":"at_most","target":100}|}));
  refused "unknown kind" (parse {|{"kind":"percent","unit":"%","target":90}|});
  refused "missing field" (parse {|{"kind":"count","noun":"층"}|});
  refused "extra field" (parse {|{"kind":"count","noun":"층","total":14,"baseline":0}|});
  refused "zero total" (parse {|{"kind":"count","noun":"층","total":0}|});
  refused "blank unit" (parse {|{"kind":"quantity","unit":" ","direction":"at_most","target":1}|});
  refused "unknown direction" (parse {|{"kind":"quantity","unit":"ms","direction":"below","target":1}|});
  refused "string target" (parse {|{"kind":"quantity","unit":"ms","direction":"at_most","target":"100"}|});
  refused "fractional total" (parse {|{"kind":"count","noun":"층","total":1.5}|});
  refused "not an object" (parse {|"count"|});
  refused "negative done" (parse_observed {|{"kind":"counted","done":-1}|});
  refused "decided as a string" (parse_observed {|{"kind":"decided","value":"yes"}|});
  refused "extra observed field" (parse_observed {|{"kind":"counted","done":1,"of":14}|})

let () =
  Alcotest.run "goal_measure"
    [ ( "goal_measure",
        [ Alcotest.test_case "constructors refuse what the types rule out" `Quick
            test_constructors_refuse_what_the_types_rule_out;
          Alcotest.test_case "reach follows the shape" `Quick test_reach_follows_the_shape;
          Alcotest.test_case "only same shapes pair" `Quick test_only_same_shapes_pair;
          Alcotest.test_case "json roundtrips" `Quick test_json_roundtrips;
          Alcotest.test_case "json reads strictly" `Quick test_json_reads_strictly ] ) ]
