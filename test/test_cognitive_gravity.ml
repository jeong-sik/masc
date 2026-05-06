(** Unit tests for Cognitive_gravity (RFC-0035 PR-1, Master Report Dim01 #5). *)

open Masc_mcp.Cognitive_gravity

let mk_item ?(keywords = []) ?(recency_seconds = 0.0)
    ?(frequency_weight = 0.0) payload =
  { payload; keywords; recency_seconds; frequency_weight }

let approx_eq a b = Float.abs (a -. b) <= 0.0001

let test_rank_empty () =
  let result = rank ~query:[ "anything" ] [] in
  Alcotest.(check int) "empty input → empty output" 0 (List.length result)

let test_rank_single_item () =
  let it = mk_item "only" ~keywords:[ "foo" ] in
  let result = rank ~query:[ "foo" ] [ it ] in
  Alcotest.(check int) "single item → single result" 1 (List.length result);
  let item, score = List.hd result in
  Alcotest.(check string) "payload preserved" "only" item.payload;
  Alcotest.(check bool) "single match scores positive" true (score > 0.0)

let test_keyword_overlap_orders_results () =
  let high = mk_item "high" ~keywords:[ "foo"; "bar" ] in
  let low = mk_item "low" ~keywords:[ "baz" ] in
  let mid = mk_item "mid" ~keywords:[ "foo"; "qux" ] in
  let result = rank ~query:[ "foo"; "bar" ] [ low; mid; high ] in
  let order = List.map (fun (item, _) -> item.payload) result in
  Alcotest.(check (list string))
    "ordered by descending overlap"
    [ "high"; "mid"; "low" ]
    order

let test_zero_weights_zero_out_components () =
  let no_kw_only_recency =
    mk_item "fresh" ~keywords:[ "miss" ] ~recency_seconds:0.0
  in
  let with_kw_old =
    mk_item "stale" ~keywords:[ "foo" ]
      ~recency_seconds:(recency_tau_seconds *. 100.0)
  in
  (* When keyword weight is zero, recency alone determines order: fresh wins. *)
  let weights_recency_only =
    { keyword = 0.0; recency = 1.0; frequency = 0.0 }
  in
  let result =
    rank ~weights:weights_recency_only ~query:[ "foo" ]
      [ with_kw_old; no_kw_only_recency ]
  in
  let order = List.map (fun (item, _) -> item.payload) result in
  Alcotest.(check (list string))
    "recency-only weights pick the fresh item even with no keyword overlap"
    [ "fresh"; "stale" ]
    order

let test_recency_decay_lowers_old_items () =
  let now = mk_item "now" ~keywords:[ "foo" ] ~recency_seconds:0.0 in
  let old =
    mk_item "old" ~keywords:[ "foo" ]
      ~recency_seconds:(recency_tau_seconds *. 5.0)
  in
  let s_now = gravity_score default_weights ~query:[ "foo" ] now in
  let s_old = gravity_score default_weights ~query:[ "foo" ] old in
  Alcotest.(check bool)
    "fresh item with same keywords scores strictly higher" true
    (s_now > s_old);
  Alcotest.(check bool)
    "negative recency clamps to 'now' (does not exceed s_now)" true
    (let neg =
       mk_item "neg" ~keywords:[ "foo" ] ~recency_seconds:(-1000.0)
     in
     let s_neg = gravity_score default_weights ~query:[ "foo" ] neg in
     approx_eq s_neg s_now)

let test_frequency_weight_clamped_to_unit_interval () =
  let it_overshoot =
    mk_item "overshoot" ~keywords:[] ~frequency_weight:5.0
  in
  let it_unit = mk_item "unit" ~keywords:[] ~frequency_weight:1.0 in
  let weights_freq_only =
    { keyword = 0.0; recency = 0.0; frequency = 1.0 }
  in
  let s_over =
    gravity_score weights_freq_only ~query:[] it_overshoot
  in
  let s_unit = gravity_score weights_freq_only ~query:[] it_unit in
  Alcotest.(check bool)
    "frequency_weight > 1.0 clamps to 1.0 (no extra reward)" true
    (approx_eq s_over s_unit)

let test_jaccard_case_insensitive () =
  let case_folded = mk_item "case" ~keywords:[ "Foo"; "BAR" ] in
  let exact = mk_item "exact" ~keywords:[ "foo"; "bar" ] in
  let case_score =
    gravity_score default_weights ~query:[ "foo"; "bar" ] case_folded
  in
  let exact_score =
    gravity_score default_weights ~query:[ "foo"; "bar" ] exact
  in
  Alcotest.(check bool)
    "case-folded match scores exactly like exact match" true
    (approx_eq case_score exact_score)

let () =
  Alcotest.run "cognitive_gravity"
    [
      ( "rank_basics",
        [
          Alcotest.test_case "empty input" `Quick test_rank_empty;
          Alcotest.test_case "single item" `Quick test_rank_single_item;
          Alcotest.test_case "keyword overlap orders" `Quick
            test_keyword_overlap_orders_results;
        ] );
      ( "weights",
        [
          Alcotest.test_case "zero weights zero out" `Quick
            test_zero_weights_zero_out_components;
          Alcotest.test_case "frequency clamp" `Quick
            test_frequency_weight_clamped_to_unit_interval;
        ] );
      ( "decay",
        [
          Alcotest.test_case "recency decay" `Quick
            test_recency_decay_lowers_old_items;
        ] );
      ( "jaccard",
        [
          Alcotest.test_case "case insensitive" `Quick
            test_jaccard_case_insensitive;
        ] );
    ]
