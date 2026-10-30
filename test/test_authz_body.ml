(* Pure checks over the body of an authorization log record: what a body may
   hold, and the exact text it is written as. No files, clock, or network.

   The expected text below was written by Python's json module
   (ensure_ascii=False, separators (",", ":")), which shares no code with this
   module. Node's JSON.stringify gives the same text for every string used
   here, and RFC 8785 section 3.2.2.2 describes the same rules. *)

module B = Authz_body

let get = function
  | Ok value -> value
  | Error error -> Alcotest.failf "refused: %s" (B.error_to_string error)
;;

let error_name = function
  | Ok _ -> "ok"
  | Error error -> B.error_to_string error
;;

(* Expected text of one string per control character U+0000 to U+001F, without
   the quotes. *)
let control_escapes =
  [ {|\u0000|}; {|\u0001|}; {|\u0002|}; {|\u0003|}; {|\u0004|}; {|\u0005|}; {|\u0006|}
  ; {|\u0007|}; {|\b|}; {|\t|}; {|\n|}; {|\u000b|}; {|\f|}; {|\r|}; {|\u000e|}; {|\u000f|}
  ; {|\u0010|}; {|\u0011|}; {|\u0012|}; {|\u0013|}; {|\u0014|}; {|\u0015|}; {|\u0016|}
  ; {|\u0017|}; {|\u0018|}; {|\u0019|}; {|\u001a|}; {|\u001b|}; {|\u001c|}; {|\u001d|}
  ; {|\u001e|}; {|\u001f|}
  ]
;;

let control_characters_are_escaped () =
  Alcotest.(check int) "one expectation per control character" 32 (List.length control_escapes);
  List.iteri
    (fun code expected ->
      Alcotest.(check string)
        (Printf.sprintf "U+%04X" code)
        ("\"" ^ expected ^ "\"")
        (B.string_literal (String.make 1 (Char.chr code))))
    control_escapes
;;

let other_characters () =
  let check label text expected =
    Alcotest.(check string) label expected (B.string_literal text)
  in
  for code = 0x20 to 0x7f do
    if code <> Char.code '"' && code <> Char.code '\\'
    then (
      let text = String.make 1 (Char.chr code) in
      check (Printf.sprintf "U+%04X as it is" code) text ("\"" ^ text ^ "\""))
  done;
  check "quote" "\"" {|"\""|};
  check "backslash" "\\" {|"\\"|};
  check "slash is not escaped" "/" {|"/"|};
  check "U+0080" "\xc2\x80" "\"\xc2\x80\"";
  check "U+00E9" "\xc3\xa9" "\"\xc3\xa9\"";
  check "U+07FF" "\xdf\xbf" "\"\xdf\xbf\"";
  check "U+0800" "\xe0\xa0\x80" "\"\xe0\xa0\x80\"";
  check "U+2028" "\xe2\x80\xa8" "\"\xe2\x80\xa8\"";
  check "U+65E5 U+672C" "\xe6\x97\xa5\xe6\x9c\xac" "\"\xe6\x97\xa5\xe6\x9c\xac\"";
  check "U+FFFF" "\xef\xbf\xbf" "\"\xef\xbf\xbf\"";
  check "U+1F600" "\xf0\x9f\x98\x80" "\"\xf0\x9f\x98\x80\"";
  check "U+10FFFF" "\xf4\x8f\xbf\xbf" "\"\xf4\x8f\xbf\xbf\"";
  check "empty" "" {|""|};
  check "mixed" "a\"b\\c\nd" {|"a\"b\\c\nd"|}
;;

(* One body that holds every kind of value. *)
let sample_json : Yojson.Safe.t =
  `Assoc
    [ ( "a"
      , `List [ `Int 1; `Int (-2); `Null; `Bool true; `Bool false; `String "x" ] )
    ; "b", `Assoc [ "c", `Assoc []; "d", `List [] ]
    ; "e", `String "\xc3\xa9"
    ; "f", `Int 9007199254740991
    ; "g", `Int (-9007199254740991)
    ]
;;

let sample_text =
  "{\"a\":[1,-2,null,true,false,\"x\"],\"b\":{\"c\":{},\"d\":[]},\"e\":\"\xc3\xa9\",\"f\":9007199254740991,\"g\":-9007199254740991}"
;;

let text_has_no_spaces_and_keeps_order () =
  Alcotest.(check string) "sample" sample_text (B.to_string (get (B.of_yojson sample_json)));
  Alcotest.(check string)
    "members keep the order given"
    {|{"b":1,"a":2}|}
    (B.to_string (get (B.object_ [ "b", get (B.int 1); "a", get (B.int 2) ])));
  Alcotest.(check string) "null" "null" (B.to_string B.null);
  Alcotest.(check string) "true" "true" (B.to_string (B.bool true));
  Alcotest.(check string) "false" "false" (B.to_string (B.bool false));
  Alcotest.(check string) "zero" "0" (B.to_string (get (B.int 0)));
  Alcotest.(check string) "empty list" "[]" (B.to_string (B.list []));
  Alcotest.(check string) "empty object" "{}" (B.to_string (get (B.object_ [])))
;;

(* Printing and parsing again gives the same value, through a parser that
   shares nothing with the printer. *)
let text_reads_back () =
  let body = get (B.of_yojson sample_json) in
  (match B.of_yojson (Yojson.Safe.from_string (B.to_string body)) with
   | Ok back -> Alcotest.(check bool) "same value" true (back = body)
   | Error error -> Alcotest.failf "printed text refused: %s" (B.error_to_string error));
  match B.of_yojson (B.to_yojson body) with
  | Ok back -> Alcotest.(check bool) "yojson round trip" true (back = body)
  | Error error -> Alcotest.failf "round trip refused: %s" (B.error_to_string error)
;;

let max_safe = 9007199254740991

let integers_stay_where_every_reader_is_exact () =
  let check label value expected =
    Alcotest.(check string) label expected (error_name (B.int value))
  in
  check "zero" 0 "ok";
  check "largest" max_safe "ok";
  check "smallest" (-max_safe) "ok";
  check "one above" (max_safe + 1) (B.error_to_string B.Integer_out_of_range);
  check "one below" (-max_safe - 1) (B.error_to_string B.Integer_out_of_range);
  check "max_int" max_int (B.error_to_string B.Integer_out_of_range);
  check "min_int" min_int (B.error_to_string B.Integer_out_of_range)
;;

let valid_utf8 =
  [ "empty", ""
  ; "ASCII", "plain text"
  ; "NUL", "\x00"
  ; "two bytes", "\xc3\xa9"
  ; "three bytes", "\xe6\x97\xa5"
  ; "four bytes", "\xf0\x9f\x98\x80"
  ; "last scalar value", "\xf4\x8f\xbf\xbf"
  ; "U+D7FF, below the surrogates", "\xed\x9f\xbf"
  ; "U+E000, above the surrogates", "\xee\x80\x80"
  ]
;;

let invalid_utf8 =
  [ "a byte that starts nothing", "\xff"
  ; "a continuation byte alone", "\x80"
  ; "an overlong NUL", "\xc0\x80"
  ; "an overlong slash", "\xe0\x80\xaf"
  ; "a surrogate", "\xed\xa0\x80"
  ; "above U+10FFFF", "\xf4\x90\x80\x80"
  ; "a cut sequence", "\xe2\x82"
  ; "a cut sequence before more text", "\xe2\x82x"
  ]
;;

let strings_must_be_utf8 () =
  List.iter
    (fun (label, text) ->
      Alcotest.(check string) label "ok" (error_name (B.string text)))
    valid_utf8;
  List.iter
    (fun (label, text) ->
      Alcotest.(check string)
        label
        (B.error_to_string B.Invalid_utf8)
        (error_name (B.string text)))
    invalid_utf8
;;

let names_must_be_utf8_and_unique () =
  let one = get (B.int 1) in
  let two = get (B.int 2) in
  let check label members expected =
    Alcotest.(check string) label expected (error_name (B.object_ members))
  in
  check "no members" [] "ok";
  check "distinct names" [ "a", one; "b", two ] "ok";
  check "names that differ only in case" [ "a", one; "A", two ] "ok";
  check
    "a repeated name"
    [ "x", one; "x", two ]
    (B.error_to_string (B.Repeated_name "x"));
  check
    "a repeated name that is not next to its twin"
    [ "b", one; "a", one; "b", two ]
    (B.error_to_string (B.Repeated_name "b"));
  check
    "the smallest repeated name is reported"
    [ "z", one; "m", one; "z", two; "m", two ]
    (B.error_to_string (B.Repeated_name "m"));
  check "a name that is not UTF-8" [ "\xff", one ] (B.error_to_string B.Invalid_utf8);
  Alcotest.(check string)
    "the same name at different depths is fine"
    "ok"
    (error_name (B.object_ [ "x", get (B.object_ [ "x", one ]) ]))
;;

let of_yojson_refuses_what_a_body_may_not_hold () =
  let check label json expected =
    Alcotest.(check string) label (B.error_to_string expected) (error_name (B.of_yojson json))
  in
  check "a float" (`Float 1.5) B.Float_not_allowed;
  check "a float that is whole" (`Float 2.0) B.Float_not_allowed;
  check "nan" (`Float Float.nan) B.Float_not_allowed;
  check "infinity" (`Float Float.infinity) B.Float_not_allowed;
  check "a float in a list" (`List [ `Int 1; `Float 2.5 ]) B.Float_not_allowed;
  check "a float in an object" (`Assoc [ "k", `Float 0.1 ]) B.Float_not_allowed;
  check "an integer too large for int" (`Intlit "123456789012345678901234567890") B.Integer_out_of_range;
  check "an int above 2^53 - 1" (`Int (max_safe + 1)) B.Integer_out_of_range;
  check "text that is not UTF-8" (`String "\xff") B.Invalid_utf8;
  check "a name that is not UTF-8" (`Assoc [ "\xc3", `Null ]) B.Invalid_utf8;
  check "a repeated name" (`Assoc [ "x", `Int 1; "x", `Int 2 ]) (B.Repeated_name "x");
  check
    "a repeated name inside a list"
    (`List [ `Assoc [ "y", `Null; "y", `Null ] ])
    (B.Repeated_name "y");
  check
    "a repeated name inside an object"
    (`Assoc [ "a", `Assoc [ "y", `Null; "y", `Null ] ])
    (B.Repeated_name "y");
  check
    "the first problem in reading order is reported"
    (`List [ `String "\xff"; `Float 1.5 ])
    B.Invalid_utf8
;;

let () =
  Alcotest.run
    "authz_body"
    [ ( "text"
      , [ Alcotest.test_case "control characters are escaped" `Quick control_characters_are_escaped
        ; Alcotest.test_case "other characters" `Quick other_characters
        ; Alcotest.test_case
            "no spaces, members keep their order"
            `Quick
            text_has_no_spaces_and_keeps_order
        ; Alcotest.test_case "text reads back" `Quick text_reads_back
        ] )
    ; ( "what a body may hold"
      , [ Alcotest.test_case
            "integers stay where every reader is exact"
            `Quick
            integers_stay_where_every_reader_is_exact
        ; Alcotest.test_case "strings must be UTF-8" `Quick strings_must_be_utf8
        ; Alcotest.test_case "names must be UTF-8 and unique" `Quick names_must_be_utf8_and_unique
        ; Alcotest.test_case
            "of_yojson refuses the rest"
            `Quick
            of_yojson_refuses_what_a_body_may_not_hold
        ] )
    ]
;;
