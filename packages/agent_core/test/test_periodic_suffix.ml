(** Periodic_suffix: the longest verbatim-cycle suffix of a byte string. *)

module P = Agent_core.Llm_provider.Periodic_suffix

let repeat n s = String.concat "" (List.init n (fun _ -> s))

let check_found name s ~max_period ~min_copies ~span ~period =
  match P.find s ~max_period ~min_copies with
  | Some found ->
    Alcotest.(check int) (name ^ ": span") span found.P.span;
    Alcotest.(check int) (name ^ ": period") period found.P.period
  | None -> Alcotest.failf "%s: expected a periodic suffix of span %d, found none" name span
;;

let check_none name s ~max_period ~min_copies =
  match P.find s ~max_period ~min_copies with
  | None -> ()
  | Some { P.span; period } ->
    Alcotest.failf "%s: expected no periodic suffix, found span %d period %d" name span period
;;

(* The three loop shapes seen in production: a multi-line chant
   (deepseek-v4.1-flash, 2026-09-14), a one-word stutter (kimi-k3,
   prime-agent#1029), a one-byte run (GLM-5.3-Flash, opencrabs#1351). *)
let test_production_shapes () =
  let chant = "Let me write.\n\nNow.\n\nGo.\n\nProducing.\n\nOK.\n\n" in
  let s = "Now I have the full rejection. 4 reasons:\n\n" ^ repeat 24 chant in
  (* The header ends in the two bytes the chant ends in, so the periodic
     suffix reaches two bytes into it. *)
  check_found "chant" s ~max_period:2730 ~min_copies:3
    ~span:((24 * String.length chant) + 2) ~period:(String.length chant);
  check_found "stutter" ("I think:" ^ repeat 50 "the ") ~max_period:2730 ~min_copies:3
    ~span:200 ~period:4;
  check_found "run" ("ok" ^ repeat 300 "!") ~max_period:2730 ~min_copies:3 ~span:300 ~period:1
;;

let test_unit_is_the_first_period_of_the_suffix () =
  let s = "prefix " ^ repeat 5 "abc" in
  match P.find s ~max_period:10 ~min_copies:3 with
  | Some found -> Alcotest.(check string) "cycle" "abc" (P.cycle s found)
  | None -> Alcotest.fail "five copies of abc must be found"
;;

(* A partial last copy still counts toward the span; copies are span / period. *)
let test_partial_last_copy_extends_the_span () =
  check_found "partial" (repeat 4 "abcd" ^ "ab") ~max_period:10 ~min_copies:3 ~span:18 ~period:4
;;

let test_below_min_copies_is_not_periodic () =
  check_none "two copies" (repeat 2 "a thought that recurs once ") ~max_period:100 ~min_copies:3;
  check_found "three copies" (repeat 3 "a thought that recurs once ") ~max_period:100
    ~min_copies:3 ~span:81 ~period:27
;;

let test_period_above_max_is_not_periodic () =
  check_none "long unit" (repeat 3 (repeat 20 "x" ^ "y")) ~max_period:20 ~min_copies:3;
  check_found "long unit allowed" (repeat 3 (repeat 20 "x" ^ "y")) ~max_period:21 ~min_copies:3
    ~span:63 ~period:21
;;

(* The longest qualifying suffix wins over a shorter, tighter one inside it. *)
let test_longest_suffix_wins () =
  let s = repeat 4 ("ab" ^ repeat 3 "c") in
  (* Suffix "ccc" has period 1; the whole string has period 5 with 4 copies. *)
  check_found "longest" s ~max_period:10 ~min_copies:3 ~span:20 ~period:5
;;

let test_prose_is_not_periodic () =
  let prose =
    "The accept gate rejects a thinking-only response and the lane rotates, so counting \
     reasoning as watchdog progress does not admit a model that only thinks. Carrier \
     frames refresh nothing."
  in
  check_none "prose" prose ~max_period:2730 ~min_copies:3;
  check_none "empty" "" ~max_period:2730 ~min_copies:3;
  check_none "one byte" "a" ~max_period:2730 ~min_copies:3
;;

let test_degenerate_arguments () =
  check_none "max_period 0" (repeat 10 "ab") ~max_period:0 ~min_copies:3;
  check_none "min_copies 1" (repeat 10 "ab") ~max_period:10 ~min_copies:1
;;

let () =
  Alcotest.run
    "periodic_suffix"
    [ ( "find"
      , [ Alcotest.test_case "production loop shapes" `Quick test_production_shapes
        ; Alcotest.test_case "unit is the first period" `Quick test_unit_is_the_first_period_of_the_suffix
        ; Alcotest.test_case "partial last copy extends the span" `Quick test_partial_last_copy_extends_the_span
        ; Alcotest.test_case "below min copies" `Quick test_below_min_copies_is_not_periodic
        ; Alcotest.test_case "period above max" `Quick test_period_above_max_is_not_periodic
        ; Alcotest.test_case "longest suffix wins" `Quick test_longest_suffix_wins
        ; Alcotest.test_case "prose" `Quick test_prose_is_not_periodic
        ; Alcotest.test_case "degenerate arguments" `Quick test_degenerate_arguments
        ] )
    ]
;;
