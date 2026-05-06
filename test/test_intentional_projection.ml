(** Unit tests for Intentional_projection (RFC-0035 PR-2,
    Master Report Dim01 #6). *)

open Masc_mcp.Intentional_projection

let approx_eq a b = Float.abs (a -. b) <= 0.0001

let test_pairs_of_short_sequences () =
  Alcotest.(check int) "empty sequence → 0 pairs" 0
    (List.length (pairs_of_sequence []));
  Alcotest.(check int) "single element → 0 pairs" 0
    (List.length (pairs_of_sequence [ "a" ]));
  let pairs = pairs_of_sequence [ "a"; "b"; "c" ] in
  Alcotest.(check int) "three elements → 2 pairs" 2 (List.length pairs);
  match pairs with
  | [ p1; p2 ] ->
    Alcotest.(check string) "first prev" "a" p1.prev;
    Alcotest.(check string) "first next" "b" p1.next;
    Alcotest.(check string) "second prev" "b" p2.prev;
    Alcotest.(check string) "second next" "c" p2.next
  | _ -> Alcotest.fail "expected exactly 2 pairs"

let test_observe_increments_total () =
  let m =
    empty
    |> Fun.flip observe_pairs (pairs_of_sequence [ "open"; "edit"; "save" ])
  in
  Alcotest.(check int) "total after 'open'" 1 (total_after m "open");
  Alcotest.(check int) "total after 'edit'" 1 (total_after m "edit");
  Alcotest.(check int) "total after 'save'" 0 (total_after m "save");
  let m2 =
    observe_pairs m (pairs_of_sequence [ "open"; "edit"; "edit"; "save" ])
  in
  Alcotest.(check int) "total after 'open' increases" 2 (total_after m2 "open");
  Alcotest.(check int) "total after 'edit' counts both edits" 3
    (total_after m2 "edit")

let test_zero_smoothing_unseen_returns_zero () =
  let m =
    observe_pairs empty (pairs_of_sequence [ "open"; "edit"; "save" ])
  in
  let s_unseen =
    score m ~smoothing:0.0 ~prev:"never" ~candidates:[ "edit"; "save" ]
      ~next:"edit"
  in
  Alcotest.(check bool)
    "unseen prev with smoothing=0 → score 0.0" true
    (approx_eq s_unseen 0.0);
  let s_seen_unseen_pair =
    score m ~smoothing:0.0 ~prev:"open"
      ~candidates:[ "edit"; "save" ]
      ~next:"save"
  in
  Alcotest.(check bool)
    "seen prev but unseen pair with smoothing=0 → 0.0" true
    (approx_eq s_seen_unseen_pair 0.0)

let test_smoothing_makes_every_candidate_positive () =
  let m =
    observe_pairs empty (pairs_of_sequence [ "open"; "edit"; "save" ])
  in
  let smoothing = 0.5 in
  let candidates = [ "edit"; "save"; "exit" ] in
  let positive_for c =
    score m ~smoothing ~prev:"open" ~candidates ~next:c > 0.0
  in
  Alcotest.(check bool)
    "edit (seen) is positive" true (positive_for "edit");
  Alcotest.(check bool)
    "save (unseen pair) becomes positive with smoothing" true
    (positive_for "save");
  Alcotest.(check bool)
    "exit (unseen pair) becomes positive with smoothing" true
    (positive_for "exit")

let test_rank_orders_by_frequency () =
  let actions =
    [ "open"; "edit"; "open"; "edit"; "open"; "save"; "open"; "edit" ]
  in
  let m = observe_pairs empty (pairs_of_sequence actions) in
  let result =
    rank m ~smoothing:0.0 ~prev:"open"
      ~candidates:[ "save"; "exit"; "edit" ]
  in
  let order = List.map fst result in
  Alcotest.(check (list string))
    "edit (seen 3x) ranks above save (1x), exit (0x) last"
    [ "edit"; "save"; "exit" ]
    order

let test_rank_empty_candidates () =
  let m = observe_pairs empty (pairs_of_sequence [ "a"; "b" ]) in
  let result = rank m ~smoothing:1.0 ~prev:"a" ~candidates:[] in
  Alcotest.(check int) "empty candidates → empty ranking" 0
    (List.length result)

let test_rank_stable_for_ties () =
  let m = empty in
  (* No observations → all candidates score equally with smoothing > 0;
     stable sort must preserve input order. *)
  let result =
    rank m ~smoothing:1.0 ~prev:"x" ~candidates:[ "c"; "a"; "b" ]
  in
  let order = List.map fst result in
  Alcotest.(check (list string))
    "tie order matches input order under stable sort"
    [ "c"; "a"; "b" ]
    order

let () =
  Alcotest.run "intentional_projection"
    [
      ( "pairs",
        [
          Alcotest.test_case "short sequences" `Quick
            test_pairs_of_short_sequences;
        ] );
      ( "observe",
        [
          Alcotest.test_case "increments totals" `Quick
            test_observe_increments_total;
        ] );
      ( "score",
        [
          Alcotest.test_case "zero smoothing unseen → 0.0" `Quick
            test_zero_smoothing_unseen_returns_zero;
          Alcotest.test_case "smoothing positive everywhere" `Quick
            test_smoothing_makes_every_candidate_positive;
        ] );
      ( "rank",
        [
          Alcotest.test_case "orders by frequency" `Quick
            test_rank_orders_by_frequency;
          Alcotest.test_case "empty candidates" `Quick
            test_rank_empty_candidates;
          Alcotest.test_case "stable for ties" `Quick test_rank_stable_for_ties;
        ] );
    ]
