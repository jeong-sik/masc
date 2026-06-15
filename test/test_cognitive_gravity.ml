(** Unit tests for Cognitive_gravity (RFC-0035 PR-1, Master Report Dim01 #5). *)

open Masc.Cognitive_gravity

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


(* ── Phase 3a/4: Memory OS scoring ── *)

let test_recency_factor_immediate () =
  let now = 1_000_000.0 in
  let r = recency_factor ~now ~last_accessed:now in
  Alcotest.(check bool) "accessed now => 1.0" true (approx_eq r 1.0)

let test_recency_factor_future () =
  let r = recency_factor ~now:100.0 ~last_accessed:200.0 in
  Alcotest.(check bool) "future access => clamp to 1.0" true (approx_eq r 1.0)

let test_access_factor_zero () =
  let a = access_factor ~count:0 in
  Alcotest.(check bool) "zero count => 0.0" true (approx_eq a 0.0)

let test_access_factor_one () =
  let a = access_factor ~count:1 in
  Alcotest.(check bool) "one access => ~1.0" true (approx_eq a 1.0)

let test_stale_penalty_none () =
  let s = stale_penalty ~last_accessed:0.0 ~expected_lifetime_cycles:None ~now:1e8 in
  Alcotest.(check bool) "no expected lifetime => 0.0" true (approx_eq s 0.0)

let test_stale_penalty_under () =
  let s = stale_penalty ~last_accessed:1e8 ~expected_lifetime_cycles:(Some 2) ~now:1e8 in
  Alcotest.(check bool) "within cycles => 0.0" true (approx_eq s 0.0)

let test_stale_penalty_over () =
  let age = 3600.0 *. 24.0 *. 7.0 *. 4.0 in (* 4 weeks *)
  let s = stale_penalty ~last_accessed:0.0 ~expected_lifetime_cycles:(Some 2) ~now:age in
  Alcotest.(check bool) "exceeds cycles => positive" true (s > 0.0)

let test_recency_bonus_hour () =
  let now = 1_000_000.0 in
  let b = recency_bonus ~now ~last_accessed:(now -. 1800.0) in
  Alcotest.(check bool) "within hour => 0.1" true (approx_eq b 0.1)

let test_recency_bonus_day () =
  let now = 1_000_000.0 in
  let b = recency_bonus ~now ~last_accessed:(now -. 43200.0) in
  Alcotest.(check bool) "within day => 0.05" true (approx_eq b 0.05)

let test_recency_bonus_old () =
  let now = 1_000_000.0 in
  let b = recency_bonus ~now ~last_accessed:(now -. 172800.0) in
  Alcotest.(check bool) "beyond day => 0.0" true (approx_eq b 0.0)

let test_valid_until_gate_none () =
  Alcotest.(check bool) "no expiry => open" true (valid_until_gate ~valid_until:None ~now:1e8)

let test_valid_until_gate_before () =
  Alcotest.(check bool) "before expiry => open" true
    (valid_until_gate ~valid_until:(Some 1e9) ~now:1e8)

let test_valid_until_gate_after () =
  Alcotest.(check bool) "after expiry => closed" false
    (valid_until_gate ~valid_until:(Some 1e8) ~now:1e9)

let test_verification_factor_of () =
  let v = verification_factor_of ~confidence:0.8 ~access_count:5 in
  Alcotest.(check bool) "confidence+access_boost > confidence" true (v > 0.8);
  Alcotest.(check bool) "capped at 1.0" true (v <= 1.0)

let test_score_fact_valid () =
  let fact = {
    confidence = 0.9;
    last_accessed = 1_000_000.0;
    access_count = 10;
    stale_penalty = 0.0;
    expected_lifetime_cycles = Some 52;
    valid_until = Some 1e9;
    verification_factor = 0.9;
  } in
  let _, score = score_fact ~now:1_000_100.0 fact in
  Alcotest.(check bool) "valid fact => positive score" true (score > 0.0)

let test_score_fact_expired () =
  let fact = {
    confidence = 0.9;
    last_accessed = 1_000_000.0;
    access_count = 10;
    stale_penalty = 0.0;
    expected_lifetime_cycles = Some 52;
    valid_until = Some 100.0;
    verification_factor = 0.9;
  } in
  let _, score = score_fact ~now:1_000_000.0 fact in
  Alcotest.(check bool) "expired => -1.0" true (approx_eq score (-1.0))
let () =
  Alcotest.run "cognitive_gravity"
    [
      ( "rank_basics_updated",
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
      ( "phase3a_recency",
        [
          Alcotest.test_case "immediate access" `Quick test_recency_factor_immediate;
          Alcotest.test_case "future access" `Quick test_recency_factor_future;
        ] );
      ( "phase3a_access",
        [
          Alcotest.test_case "zero count" `Quick test_access_factor_zero;
          Alcotest.test_case "one access" `Quick test_access_factor_one;
        ] );
      ( "phase3a_stale",
        [
          Alcotest.test_case "no penalty" `Quick test_stale_penalty_none;
          Alcotest.test_case "within cycles" `Quick test_stale_penalty_under;
          Alcotest.test_case "exceeds cycles" `Quick test_stale_penalty_over;
        ] );
      ( "phase3a_recency_bonus",
        [
          Alcotest.test_case "within hour" `Quick test_recency_bonus_hour;
          Alcotest.test_case "within day" `Quick test_recency_bonus_day;
          Alcotest.test_case "beyond day" `Quick test_recency_bonus_old;
        ] );
      ( "phase4_gate",
        [
          Alcotest.test_case "no expiry" `Quick test_valid_until_gate_none;
          Alcotest.test_case "before expiry" `Quick test_valid_until_gate_before;
          Alcotest.test_case "after expiry" `Quick test_valid_until_gate_after;
        ] );
      ( "phase4_verification",
        [
          Alcotest.test_case "verification factor" `Quick test_verification_factor_of;
        ] );
      ( "phase4_score_fact",
        [
          Alcotest.test_case "valid fact" `Quick test_score_fact_valid;
          Alcotest.test_case "expired fact" `Quick test_score_fact_expired;
        ] );
