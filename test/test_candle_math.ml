(** The integer arithmetic of a payout (RFC-goal-candle-ledger 3.3, 3.4): the
    overdue hours, the deduction coefficient, the split among Keepers, and the
    deduction, including the edges that are easy to get wrong. *)

let time text =
  match Ptime.of_rfc3339 ~strict:true text with
  | Ok (instant, _, _) -> instant
  | Error _ -> Alcotest.failf "%S is not a timestamp" text
;;

let ok_or_fail = function
  | Ok value -> value
  | Error error -> Alcotest.failf "%s" (Candle_math.error_to_string error)
;;

let is_error label expected = function
  | Ok _ -> Alcotest.failf "%s: expected an error" label
  | Error error -> Alcotest.(check bool) label true (error = expected)
;;

(* {1 Overdue hours} *)

let test_overdue_hours_are_whole_hours_rounded_down () =
  let due = time "2026-09-26T23:59:59Z" in
  let hours passed_at = Candle_math.overdue_hours ~due ~passed_at:(time passed_at) in
  Alcotest.(check int) "at the due moment" 0 (hours "2026-09-26T23:59:59Z");
  Alcotest.(check int) "one second late" 0 (hours "2026-09-27T00:00:00Z");
  Alcotest.(check int) "59 minutes 59 seconds late" 0 (hours "2026-09-27T00:59:58Z");
  Alcotest.(check int) "exactly one hour late" 1 (hours "2026-09-27T00:59:59Z");
  Alcotest.(check int) "the RFC's example: 30 hours 32 minutes" 30 (hours "2026-09-28T06:32:00Z");
  Alcotest.(check int) "ten days late" 240 (hours "2026-10-06T23:59:59Z")
;;

let test_finishing_early_is_never_overdue () =
  let due = time "2026-09-26T23:59:59Z" in
  let hours passed_at = Candle_math.overdue_hours ~due ~passed_at:(time passed_at) in
  Alcotest.(check int) "one second early" 0 (hours "2026-09-26T23:59:58Z");
  Alcotest.(check int) "a month early" 0 (hours "2026-08-26T00:00:00Z")
;;

(* {1 Deduction coefficient} *)

let coefficient ~overdue_hours =
  ok_or_fail (Candle_math.deduction_coefficient ~rate:10 ~floor:200 ~overdue_hours)
;;

let test_the_coefficient_falls_by_the_rate_and_stops_at_the_floor () =
  List.iter
    (fun (hours, expected) ->
       Alcotest.(check int) (Printf.sprintf "%d hours late" hours) expected (coefficient ~overdue_hours:hours))
    [ 0, 1000; 1, 990; 10, 900; 30, 700; 50, 500; 79, 210; 80, 200; 81, 200; 100, 200; 100_000, 200 ]
;;

let test_a_huge_number_of_hours_does_not_wrap () =
  Alcotest.(check int) "max_int hours" 200 (coefficient ~overdue_hours:max_int);
  Alcotest.(check int)
    "rate 1000 and max_int hours"
    0
    (ok_or_fail (Candle_math.deduction_coefficient ~rate:1000 ~floor:0 ~overdue_hours:max_int))
;;

let test_a_rate_of_zero_or_a_floor_of_a_thousand_takes_nothing () =
  Alcotest.(check int)
    "rate 0"
    1000
    (ok_or_fail (Candle_math.deduction_coefficient ~rate:0 ~floor:0 ~overdue_hours:5000));
  Alcotest.(check int)
    "floor 1000"
    1000
    (ok_or_fail (Candle_math.deduction_coefficient ~rate:1000 ~floor:1000 ~overdue_hours:5000))
;;

let test_a_rate_or_floor_outside_the_range_is_refused () =
  let coefficient ~rate ~floor = Candle_math.deduction_coefficient ~rate ~floor ~overdue_hours:1 in
  is_error "negative rate" (Candle_math.Rate_out_of_range (-1)) (coefficient ~rate:(-1) ~floor:0);
  is_error "rate above 1000" (Candle_math.Rate_out_of_range 1001) (coefficient ~rate:1001 ~floor:0);
  is_error "negative floor" (Candle_math.Rate_out_of_range (-5)) (coefficient ~rate:10 ~floor:(-5));
  is_error "floor above 1000" (Candle_math.Rate_out_of_range 2000) (coefficient ~rate:10 ~floor:2000);
  is_error
    "negative hours"
    (Candle_math.Negative_hours (-1))
    (Candle_math.deduction_coefficient ~rate:10 ~floor:200 ~overdue_hours:(-1))
;;

(* {1 Split} *)

let split ~total weights = ok_or_fail (Candle_math.split ~rounding:Candle_math.Largest_remainder ~tie_break:Candle_math.Name_ascending ~total weights)

let test_a_split_gives_the_leftover_to_the_largest_remainders () =
  Alcotest.(check (list (pair string int)))
    "100 by 3:2:1"
    [ "a", 50; "b", 33; "c", 17 ]
    (split ~total:100 [ "a", 3; "b", 2; "c", 1 ]);
  Alcotest.(check (list (pair string int)))
    "10 by 1:1:1 goes to the name that sorts first"
    [ "b", 3; "a", 4; "c", 3 ]
    (split ~total:10 [ "b", 1; "a", 1; "c", 1 ]);
  Alcotest.(check (list (pair string int)))
    "10 by seven equal weights (three left over, to the first three names)"
    [ "g", 1; "f", 1; "e", 1; "d", 1; "c", 2; "b", 2; "a", 2 ]
    (split ~total:10 [ "g", 1; "f", 1; "e", 1; "d", 1; "c", 1; "b", 1; "a", 1 ])
;;

let test_the_names_come_back_in_the_order_given () =
  Alcotest.(check (list string))
    "order"
    [ "zed"; "amy"; "kim" ]
    (List.map fst (split ~total:9 [ "zed", 1; "amy", 1; "kim", 1 ]))
;;

let test_a_zero_weight_gets_nothing_and_one_name_gets_everything () =
  Alcotest.(check (list (pair string int)))
    "zero weight"
    [ "a", 7; "b", 0 ]
    (split ~total:7 [ "a", 5; "b", 0 ]);
  Alcotest.(check (list (pair string int))) "one name" [ "only", 12345 ] (split ~total:12345 [ "only", 9 ]);
  Alcotest.(check (list (pair string int))) "nothing to share" [ "a", 0; "b", 0 ] (split ~total:0 [ "a", 1; "b", 2 ])
;;

let test_split_checks_inputs_and_preserves_large_results () =
  is_error "negative total" Candle_math.Negative_total (Candle_math.split ~rounding:Candle_math.Largest_remainder ~tie_break:Candle_math.Name_ascending ~total:(-1) [ "a", 1 ]);
  is_error "no names" Candle_math.No_weight (Candle_math.split ~rounding:Candle_math.Largest_remainder ~tie_break:Candle_math.Name_ascending ~total:5 []);
  is_error "all zero" Candle_math.No_weight (Candle_math.split ~rounding:Candle_math.Largest_remainder ~tie_break:Candle_math.Name_ascending ~total:5 [ "a", 0; "b", 0 ]);
  is_error "negative weight" (Candle_math.Negative_weight "b") (Candle_math.split ~rounding:Candle_math.Largest_remainder ~tie_break:Candle_math.Name_ascending ~total:5 [ "a", 1; "b", -1 ]);
  is_error "a name twice" (Candle_math.Duplicate_name "a") (Candle_math.split ~rounding:Candle_math.Largest_remainder ~tie_break:Candle_math.Name_ascending ~total:5 [ "a", 1; "b", 1; "a", 2 ]);
  Alcotest.(check (list (pair string int))) "representable shares despite a large product"
    [ "a", 2 * (max_int / 3); "b", max_int / 3 ]
    (split ~total:max_int [ "a", 2; "b", 1 ]);
  Alcotest.(check (list (pair string int))) "representable shares despite a large weight sum"
    [ "a", 1; "b", 0 ] (split ~total:1 [ "a", max_int; "b", 1 ])
;;

let random_case state =
  let names = [| "amy"; "bob"; "cyd"; "dan"; "eve"; "fay"; "gus"; "hal" |] in
  let count = 1 + Random.State.int state (Array.length names) in
  let weights =
    List.init count (fun i -> names.(i), if Random.State.int state 5 = 0 then 0 else Random.State.int state 1_000)
  in
  let total = Random.State.int state 1_000_000_000 in
  total, weights
;;

let test_the_shares_always_sum_to_the_total_and_stay_within_one_of_exact () =
  let state = Random.State.make [| 20260929 |] in
  for _ = 1 to 3000 do
    let total, weights = random_case state in
    let sum = List.fold_left (fun acc (_, weight) -> acc + weight) 0 weights in
    match Candle_math.split ~rounding:Candle_math.Largest_remainder ~tie_break:Candle_math.Name_ascending ~total weights with
    | Error Candle_math.No_weight -> Alcotest.(check int) "only when every weight is zero" 0 sum
    | Error error -> Alcotest.failf "%s" (Candle_math.error_to_string error)
    | Ok shares ->
      Alcotest.(check int) "sum" total (List.fold_left (fun acc (_, share) -> acc + share) 0 shares);
      List.iter2
        (fun (_, weight) (name, share) ->
           let exact_floor = total * weight / sum in
           if share < exact_floor || share > exact_floor + 1
           then Alcotest.failf "%s: %d is not within one of %d" name share exact_floor;
           if weight = 0 && share <> 0 then Alcotest.failf "%s has no weight but was paid" name)
        weights
        shares
  done
;;

let test_the_split_does_not_depend_on_the_order_names_are_given_in () =
  let state = Random.State.make [| 7 |] in
  for _ = 1 to 500 do
    let total, weights = random_case state in
    match Candle_math.split ~rounding:Candle_math.Largest_remainder ~tie_break:Candle_math.Name_ascending ~total weights with
    | Error _ -> ()
    | Ok shares ->
      let reversed = List.rev weights in
      let by_name pairs = List.sort compare pairs in
      Alcotest.(check (list (pair string int)))
        "same amount per name"
        (by_name shares)
        (by_name (split ~total reversed))
  done
;;

(* {1 Deduct} *)

let test_a_deduction_rounds_down () =
  let deduct ~coefficient share = ok_or_fail (Candle_math.deduct ~rounding:Candle_math.Floor ~coefficient share) in
  Alcotest.(check int) "10000 at 70%" 7000 (deduct ~coefficient:700 10_000);
  Alcotest.(check int) "999 at 70% is 699.3" 699 (deduct ~coefficient:700 999);
  Alcotest.(check int) "at 100% nothing is taken" 12_345 (deduct ~coefficient:1000 12_345);
  Alcotest.(check int) "at 0% nothing is paid" 0 (deduct ~coefficient:0 12_345);
  Alcotest.(check int) "a share of zero" 0 (deduct ~coefficient:700 0)
;;

let test_deduction_checks_inputs_and_preserves_large_results () =
  is_error "coefficient above 1000" (Candle_math.Rate_out_of_range 1001) (Candle_math.deduct ~rounding:Candle_math.Floor ~coefficient:1001 5);
  is_error "coefficient below 0" (Candle_math.Rate_out_of_range (-1)) (Candle_math.deduct ~rounding:Candle_math.Floor ~coefficient:(-1) 5);
  Alcotest.(check int) "identity deduction preserves the largest public amount"
    max_int (ok_or_fail (Candle_math.deduct ~rounding:Candle_math.Floor ~coefficient:1000 max_int))
;;

let test_negative_shares_never_become_payments () =
  List.iter
    (fun share ->
       List.iter
         (fun coefficient ->
            is_error "a negative input cannot mint or destroy a payment"
              (Candle_math.Negative_share share)
              (Candle_math.deduct ~rounding:Candle_math.Floor ~coefficient share))
         [ 0; 1; 500; 999; 1000 ])
    [ -1; -1000; min_int; min_int + 1 ]
;;

(* {1 Wallet decay} *)

let decay_time text =
  match Candle_time.of_rfc3339 text with
  | Ok instant -> instant
  | Error error -> Alcotest.failf "%s" error
;;

let decay ~half_life ~since ~at amount_milli =
  match Candle_decay.remaining ~half_life ~since:(decay_time since) ~at:(decay_time at) ~amount_milli with
  | Ok amount -> amount
  | Error error -> Alcotest.failf "%s" (Candle_decay.error_to_string error)
;;

let test_decay_requires_valid_policy_money_and_time () =
  List.iter
    (fun hours ->
       match Candle_decay.half_life_of_hours hours with
       | Error _ -> Alcotest.failf "positive half-life %d was refused" hours
       | Ok policy -> Alcotest.(check bool) "closed Hours value" true (policy = Candle_decay.Hours hours))
    [ 1; max_int ];
  List.iter
    (fun hours ->
       match Candle_decay.half_life_of_hours hours with
       | Ok _ -> Alcotest.failf "non-positive half-life %d was accepted" hours
       | Error _ -> ())
    [ 0; -1; min_int ];
  let since = decay_time "2026-09-30T00:00:00Z" in
  let error label expected result =
    match result with
    | Ok _ -> Alcotest.failf "%s: expected an error" label
    | Error actual -> Alcotest.(check bool) label true (actual = expected)
  in
  error "negative money even with Off" (Candle_decay.Negative_amount (-1))
    (Candle_decay.remaining ~half_life:Candle_decay.Off ~since ~at:since ~amount_milli:(-1));
  error "reversed time even with Off" Candle_decay.Reversed_interval
    (Candle_decay.remaining ~half_life:Candle_decay.Off ~since
       ~at:(decay_time "2026-09-29T23:59:59Z") ~amount_milli:1);
  error "invalid raw Hours rejected before zero or identity shortcuts" (Candle_decay.Non_positive_hours 0)
    (Candle_decay.remaining ~half_life:(Candle_decay.Hours 0) ~since ~at:since ~amount_milli:0)
;;

let test_decay_off_and_exact_half_lives () =
  let since = "2026-09-30T00:00:00Z" in
  Alcotest.(check int) "Off preserves maximum money across centuries" max_int
    (decay ~half_life:Candle_decay.Off ~since:"0001-01-01T00:00:00Z" ~at:"9999-12-31T23:59:59Z" max_int);
  Alcotest.(check int) "equal instants preserve maximum money" max_int
    (decay ~half_life:(Candle_decay.Hours 1) ~since ~at:since max_int);
  List.iter
    (fun (at, expected) ->
       Alcotest.(check int) at expected (decay ~half_life:(Candle_decay.Hours 1) ~since ~at 1000))
    [ "2026-09-30T01:00:00Z", 500; "2026-09-30T02:00:00Z", 250 ];
  Alcotest.(check int) "odd money has one exact whole-period floor" 1
    (decay ~half_life:(Candle_decay.Hours 1) ~since ~at:"2026-09-30T01:00:00Z" 3);
  Alcotest.(check int) "exact half of maximum public money" (max_int / 2)
    (decay ~half_life:(Candle_decay.Hours 1) ~since ~at:"2026-09-30T01:00:00Z" max_int);
  Alcotest.(check int) "zero stays zero" 0
    (decay ~half_life:(Candle_decay.Hours 1) ~since ~at:"2026-09-30T00:00:01Z" 0);
  Alcotest.(check int) "many whole periods reach zero without exponent conversion" 0
    (decay ~half_life:(Candle_decay.Hours 1) ~since:"0001-01-01T00:00:00Z"
       ~at:"9999-12-31T23:59:59Z" max_int)
;;

let test_fractional_decay_has_one_final_money_floor () =
  let since = "2026-09-30T00:00:00Z" in
  (* The half-period root lies strictly between 707/1000 and 708/1000. *)
  Alcotest.(check int) "one half of a half-life" 707
    (decay ~half_life:(Candle_decay.Hours 2) ~since ~at:"2026-09-30T01:00:00Z" 1000);
  Alcotest.(check int) "3 milli after 1.5 periods is not prematurely halved" 1
    (decay ~half_life:(Candle_decay.Hours 2) ~since ~at:"2026-09-30T03:00:00Z" 3);
  (* 793^3 < 1000^3/2 < 794^3, with ample room for the Q128 error bound. *)
  Alcotest.(check int) "one third of a half-life" 793
    (decay ~half_life:(Candle_decay.Hours 3) ~since ~at:"2026-09-30T01:00:00Z" 1000);
  let before = decay ~half_life:(Candle_decay.Hours 1) ~since ~at:"2026-09-30T00:59:59Z" max_int in
  let exact = decay ~half_life:(Candle_decay.Hours 1) ~since ~at:"2026-09-30T01:00:00Z" max_int in
  let after = decay ~half_life:(Candle_decay.Hours 1) ~since ~at:"2026-09-30T01:00:01Z" max_int in
  Alcotest.(check bool) "whole-second ticks never increase money at a period boundary" true
    (before >= exact && exact >= after)
;;

let test_decay_large_periods_and_small_money () =
  let since = "2026-09-30T00:00:00Z" in
  (* For amount=hours=max_int and elapsed=1 second, ideal positive loss is
     below 1/3600 milli; quantization is also below one, far from the next floor. *)
  Alcotest.(check int) "maximum hours do not overflow the seconds period" (max_int - 1)
    (decay ~half_life:(Candle_decay.Hours max_int) ~since ~at:"2026-09-30T00:00:01Z" max_int);
  Alcotest.(check int) "one milli floors to zero after any positive fractional decay" 0
    (decay ~half_life:(Candle_decay.Hours max_int) ~since ~at:"2026-09-30T00:00:01Z" 1)
;;

let () =
  Alcotest.run
    "candle_math"
    [ ( "overdue_hours"
      , [ Alcotest.test_case "whole hours rounded down" `Quick test_overdue_hours_are_whole_hours_rounded_down
        ; Alcotest.test_case "finishing early is never overdue" `Quick test_finishing_early_is_never_overdue
        ] )
    ; ( "deduction_coefficient"
      , [ Alcotest.test_case "falls by the rate and stops at the floor" `Quick
            test_the_coefficient_falls_by_the_rate_and_stops_at_the_floor
        ; Alcotest.test_case "a huge number of hours does not wrap" `Quick
            test_a_huge_number_of_hours_does_not_wrap
        ; Alcotest.test_case "a rate of zero or a floor of a thousand takes nothing" `Quick
            test_a_rate_of_zero_or_a_floor_of_a_thousand_takes_nothing
        ; Alcotest.test_case "a rate or floor outside the range is refused" `Quick
            test_a_rate_or_floor_outside_the_range_is_refused
        ] )
    ; ( "split"
      , [ Alcotest.test_case "the leftover goes to the largest remainders" `Quick
            test_a_split_gives_the_leftover_to_the_largest_remainders
        ; Alcotest.test_case "names come back in the order given" `Quick
            test_the_names_come_back_in_the_order_given
        ; Alcotest.test_case "zero weight gets nothing and one name gets everything" `Quick
            test_a_zero_weight_gets_nothing_and_one_name_gets_everything
        ; Alcotest.test_case "split checks inputs and preserves large results" `Quick
            test_split_checks_inputs_and_preserves_large_results
        ; Alcotest.test_case "shares sum to the total and stay within one of exact" `Quick
            test_the_shares_always_sum_to_the_total_and_stay_within_one_of_exact
        ; Alcotest.test_case "the split does not depend on the order of names" `Quick
            test_the_split_does_not_depend_on_the_order_names_are_given_in
        ] )
    ; ( "deduct"
      , [ Alcotest.test_case "a deduction rounds down" `Quick test_a_deduction_rounds_down
        ; Alcotest.test_case "negative shares never become payments" `Quick
            test_negative_shares_never_become_payments
        ; Alcotest.test_case "deduction checks inputs and preserves large results" `Quick
            test_deduction_checks_inputs_and_preserves_large_results
        ] )
    ; ( "decay"
      , [ Alcotest.test_case "valid explicit policy, money and time" `Quick
            test_decay_requires_valid_policy_money_and_time
        ; Alcotest.test_case "Off and exact half-lives" `Quick test_decay_off_and_exact_half_lives
        ; Alcotest.test_case "fractional decay has one final money floor" `Quick
            test_fractional_decay_has_one_final_money_floor
        ; Alcotest.test_case "large periods and small money" `Quick test_decay_large_periods_and_small_money
        ] )
    ]
;;
