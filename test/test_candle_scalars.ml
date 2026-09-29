(** The small values under the Candle ledger: milli-candle, whole-second
    times, calendar dates, keeper names and the item catalog. *)

module Look = Keeper_portrait_look

let is_error = function
  | Ok _ -> false
  | Error _ -> true
;;

let check_error label result = Alcotest.(check bool) label true (is_error result)

let milli amount =
  match Candle_milli.of_int amount with
  | Ok value -> value
  | Error error -> Alcotest.failf "%s" (Candle_milli.error_to_string error)
;;

(* -- Candle_milli -- *)

let test_milli_refuses_a_negative_amount () =
  Alcotest.(check bool)
    "negative"
    true
    (Candle_milli.of_int (-1) = Error (Candle_milli.Negative (-1)));
  Alcotest.(check int) "zero" 0 (Candle_milli.to_int (milli 0))
;;

let test_milli_names_overflow_instead_of_wrapping () =
  let top = milli max_int in
  Alcotest.(check bool) "max + 1" true (Candle_milli.add top (milli 1) = Error Candle_milli.Overflow);
  Alcotest.(check bool)
    "max + max"
    true
    (Candle_milli.add top top = Error Candle_milli.Overflow);
  Alcotest.(check bool)
    "sum"
    true
    (Candle_milli.sum [ top; milli 1 ] = Error Candle_milli.Overflow);
  Alcotest.(check int)
    "the largest sum that fits"
    max_int
    (Candle_milli.to_int (Result.get_ok (Candle_milli.add (milli (max_int - 1)) (milli 1))))
;;

let test_milli_sub_never_clamps () =
  Alcotest.(check bool) "more than held" true (Candle_milli.sub (milli 5) (milli 6) = None);
  Alcotest.(check bool)
    "exactly held"
    true
    (Candle_milli.sub (milli 5) (milli 5) = Some (milli 0))
;;

let test_milli_reads_only_a_json_integer () =
  Alcotest.(check bool) "int" true (Candle_milli.of_yojson (`Int 500) = Ok (milli 500));
  List.iter
    (fun (label, json) -> check_error label (Candle_milli.of_yojson json))
    [ "float", `Float 500.0
    ; "string", `String "500"
    ; "negative", `Int (-1)
    ; "beyond 63 bits", `Intlit "4611686018427387904"
    ; "null", `Null
    ]
;;

(* -- Candle_time -- *)

let test_time_reads_only_what_it_writes () =
  let text = "2026-09-29T06:00:00Z" in
  (match Candle_time.of_rfc3339 text with
   | Ok instant -> Alcotest.(check string) "round trip" text (Candle_time.to_rfc3339 instant)
   | Error detail -> Alcotest.failf "%s" detail);
  List.iter
    (fun (label, text) -> check_error label (Candle_time.of_rfc3339 text))
    [ "offset", "2026-09-29T15:00:00+09:00"
    ; "fraction", "2026-09-29T06:00:00.5Z"
    ; "lowercase z", "2026-09-29T06:00:00z"
    ; "space", "2026-09-29 06:00:00Z"
    ; "short month", "2026-9-29T06:00:00Z"
    ; "date only", "2026-09-29"
    ; "trailing text", "2026-09-29T06:00:00Z "
    ]
;;

let test_time_truncates_a_source_fraction () =
  match Ptime.of_rfc3339 "2026-09-29T06:00:00.750Z" with
  | Error _ -> Alcotest.fail "the probe timestamp does not parse"
  | Ok (instant, _, _) ->
    Alcotest.(check string)
      "whole second"
      "2026-09-29T06:00:00Z"
      (Candle_time.to_rfc3339 (Candle_time.of_ptime instant))
;;

let test_time_compares_like_its_text () =
  let earlier = Result.get_ok (Candle_time.of_rfc3339 "2026-09-29T06:00:00Z") in
  let later = Result.get_ok (Candle_time.of_rfc3339 "2026-09-29T06:00:01Z") in
  Alcotest.(check bool) "before" true (Candle_time.compare earlier later < 0);
  Alcotest.(check bool) "equal" true (Candle_time.equal earlier earlier)
;;

(* -- Candle_time.Date -- *)

let test_date_accepts_a_calendar_day () =
  match Candle_time.Date.of_string "2026-09-26" with
  | Some date -> Alcotest.(check string) "round trip" "2026-09-26" (Candle_time.Date.to_string date)
  | None -> Alcotest.fail "a real date was refused"
;;

let test_date_refuses_what_the_calendar_or_the_format_does_not_have () =
  List.iter
    (fun (label, text) ->
       Alcotest.(check bool) label true (Candle_time.Date.of_string text = None))
    [ "short month and day", "2026-9-3"
    ; "day the month lacks", "2026-02-30"
    ; "month 13", "2026-13-01"
    ; "leading space", " 2026-09-03"
    ; "trailing space", "2026-09-03 "
    ; "slashes", "2026/09/03"
    ; "empty", ""
    ; "text", "TBD"
    ; "timestamp", "2026-09-03T00:00:00Z"
    ; "non-ASCII digit", "20\xd9\xa2-09-03"
    ]
;;

(* -- Candle_keeper -- *)

let test_keeper_name_is_trimmed_and_lowercased () =
  let name text = Option.map Candle_keeper.to_string (Candle_keeper.of_string text) in
  Alcotest.(check (option string)) "canonical" (Some "alice") (name "  Alice ");
  Alcotest.(check (option string)) "blank" None (name "   ")
;;

let test_keeper_json_must_already_be_canonical () =
  Alcotest.(check bool)
    "canonical"
    true
    (Result.is_ok (Candle_keeper.of_yojson (`String "alice")));
  check_error "uppercase" (Candle_keeper.of_yojson (`String "Alice"));
  check_error "padded" (Candle_keeper.of_yojson (`String " alice"));
  check_error "blank" (Candle_keeper.of_yojson (`String ""));
  check_error "not a string" (Candle_keeper.of_yojson (`Int 1))
;;

(* [Candle_keeper] sits below the library that owns [Keeper_identity.Keeper_id],
   so it spells the same rule again. An input the two treat differently would be
   a ledger row naming a keeper the rest of the server does not know. *)
let test_keeper_name_rule_is_keeper_identitys () =
  List.iter
    (fun input ->
       Alcotest.(check (option string))
         (Printf.sprintf "%S" input)
         (Option.map
            Masc.Keeper_identity.Keeper_id.to_string
            (Masc.Keeper_identity.Keeper_id.of_string input))
         (Option.map Candle_keeper.to_string (Candle_keeper.of_string input)))
    [ "alice"; " Alice "; "ALICE"; ""; "   "; "\tbob\n"; "\xc3\x89mile"; "a b"; "keeper-1" ]
;;

(* -- Candle_item -- *)

let test_item_names_are_written_once_and_read_back () =
  Alcotest.(check int) "eighteen items" 18 (List.length Candle_item.all);
  List.iter
    (fun item ->
       let wire = Candle_item.to_wire item in
       Alcotest.(check (option string))
         wire
         (Some wire)
         (Option.map Candle_item.to_wire (Candle_item.of_wire wire)))
    Candle_item.all;
  let wires = List.map Candle_item.to_wire Candle_item.all in
  Alcotest.(check int)
    "no two items share a name"
    (List.length wires)
    (List.length (List.sort_uniq String.compare wires));
  Alcotest.(check bool) "unknown" true (Candle_item.of_wire "top_hat" = None)
;;

let test_slot_names_read_back () =
  List.iter
    (fun slot ->
       let wire = Candle_item.slot_to_wire slot in
       Alcotest.(check (option string))
         wire
         (Some wire)
         (Option.map Candle_item.slot_to_wire (Candle_item.slot_of_wire wire)))
    Candle_item.slots;
  Alcotest.(check int) "five slots" 5 (List.length Candle_item.slots)
;;

(* The portrait renderer owns what can be worn. Adding a constructor there
   stops this file compiling here, and the catalog comparison below fails until
   [Candle_item] has the same item. *)
let of_face = function
  | Look.Bare_face -> None
  | Look.Glasses -> Some Candle_item.Glasses
  | Look.Shades -> Some Candle_item.Shades
  | Look.Eye_patch -> Some Candle_item.Eye_patch
  | Look.Plaster -> Some Candle_item.Plaster
  | Look.Freckles -> Some Candle_item.Freckles
  | Look.Beard -> Some Candle_item.Beard
;;

let of_neck = function
  | Look.Bare_neck -> None
  | Look.Scarf -> Some Candle_item.Scarf
  | Look.Bow_tie -> Some Candle_item.Bow_tie
  | Look.Medal -> Some Candle_item.Medal
;;

let of_head = function
  | Look.Bare_head -> None
  | Look.Bow -> Some Candle_item.Bow
  | Look.Crown -> Some Candle_item.Crown
  | Look.Beanie -> Some Candle_item.Beanie
;;

let of_hand = function
  | Look.Empty_hand -> None
  | Look.Book -> Some Candle_item.Book
  | Look.Mug -> Some Candle_item.Mug
  | Look.Quill -> Some Candle_item.Quill
;;

let of_base = function
  | Look.No_dish -> None
  | Look.Dish Look.Gilt -> Some Candle_item.Gilt_dish
  | Look.Dish Look.Silver -> Some Candle_item.Silver_dish
  | Look.Dish Look.Oak -> Some Candle_item.Oak_dish
;;

let test_the_catalog_is_what_the_portrait_can_wear () =
  let expect_slot slot items =
    List.iter
      (fun item ->
         Alcotest.(check string)
           (Candle_item.to_wire item)
           (Candle_item.slot_to_wire slot)
           (Candle_item.slot_to_wire (Candle_item.slot item)))
      items
  in
  let face = List.filter_map of_face Look.all_face_items in
  let neck = List.filter_map of_neck Look.all_neck_items in
  let head = List.filter_map of_head Look.all_head_items in
  let hand = List.filter_map of_hand Look.all_hand_items in
  let base = List.filter_map of_base Look.all_base_items in
  expect_slot Candle_item.Face face;
  expect_slot Candle_item.Neck neck;
  expect_slot Candle_item.Head head;
  expect_slot Candle_item.Hand hand;
  expect_slot Candle_item.Base base;
  let wires items = List.sort String.compare (List.map Candle_item.to_wire items) in
  Alcotest.(check (list string))
    "same items"
    (wires (face @ neck @ head @ hand @ base))
    (wires Candle_item.all)
;;

let () =
  Alcotest.run
    "candle_scalars"
    [ ( "milli"
      , [ Alcotest.test_case "refuses a negative amount" `Quick test_milli_refuses_a_negative_amount
        ; Alcotest.test_case
            "names overflow instead of wrapping"
            `Quick
            test_milli_names_overflow_instead_of_wrapping
        ; Alcotest.test_case "sub never clamps" `Quick test_milli_sub_never_clamps
        ; Alcotest.test_case
            "reads only a JSON integer"
            `Quick
            test_milli_reads_only_a_json_integer
        ] )
    ; ( "time"
      , [ Alcotest.test_case "reads only what it writes" `Quick test_time_reads_only_what_it_writes
        ; Alcotest.test_case
            "truncates a source fraction"
            `Quick
            test_time_truncates_a_source_fraction
        ; Alcotest.test_case "compares like its text" `Quick test_time_compares_like_its_text
        ] )
    ; ( "date"
      , [ Alcotest.test_case "accepts a calendar day" `Quick test_date_accepts_a_calendar_day
        ; Alcotest.test_case
            "refuses what the calendar or the format does not have"
            `Quick
            test_date_refuses_what_the_calendar_or_the_format_does_not_have
        ] )
    ; ( "keeper"
      , [ Alcotest.test_case
            "name is trimmed and lowercased"
            `Quick
            test_keeper_name_is_trimmed_and_lowercased
        ; Alcotest.test_case
            "json must already be canonical"
            `Quick
            test_keeper_json_must_already_be_canonical
        ; Alcotest.test_case
            "name rule is Keeper_identity's"
            `Quick
            test_keeper_name_rule_is_keeper_identitys
        ] )
    ; ( "item"
      , [ Alcotest.test_case
            "names are written once and read back"
            `Quick
            test_item_names_are_written_once_and_read_back
        ; Alcotest.test_case "slot names read back" `Quick test_slot_names_read_back
        ; Alcotest.test_case
            "the catalog is what the portrait can wear"
            `Quick
            test_the_catalog_is_what_the_portrait_can_wear
        ] )
    ]
;;
