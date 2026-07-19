(* RFC 5545 §3.1 content-line tests for Schedule_ical_content_line.

   Covers physical splitting (CRLF / bare LF / lone CR), folding, the
   name/param/value split with quoted-string protection, and the typed
   rejection of every malformed shape. *)

open Alcotest
module C = Schedule_ical_content_line

let parse_ok line =
  match C.parse ~line:1 line with
  | Ok cl -> cl
  | Error e -> failf "parse %S rejected: %s" line (C.parse_error_to_string e)

let parse_error line =
  match C.parse ~line:1 line with
  | Ok _ -> failf "parse %S unexpectedly accepted" line
  | Error e -> e

(* ---------------------------------------------------------------- *)
(* Unfold                                                           *)
(* ---------------------------------------------------------------- *)

let test_unfold_crlf_basic () =
  match C.unfold "A:1\r\nB:2\r\n" with
  | Ok [ "A:1"; "B:2" ] -> ()
  | Ok other -> failf "wrong lines: %d" (List.length other)
  | Error e -> fail (C.parse_error_to_string e)

let test_unfold_bare_lf_accepted () =
  match C.unfold "A:1\nB:2\n" with
  | Ok [ "A:1"; "B:2" ] -> ()
  | _ -> fail "bare LF lines must split"

let test_unfold_lone_cr_rejected () =
  match C.unfold "A:1\rB:2" with
  | Error (C.Lone_carriage_return _) -> ()
  | _ -> fail "lone CR must be a typed error"

let test_unfold_folding_rejoins () =
  (* CRLF followed by SPACE or HTAB is removed with the whitespace. *)
  match C.unfold "DESCRIPTION:This is a lo\r\n ng description\r\n" with
  | Ok [ "DESCRIPTION:This is a long description" ] -> ()
  | Ok other ->
    failf "fold produced %d lines" (List.length other)
  | Error e -> fail (C.parse_error_to_string e)

let test_unfold_folding_tab () =
  match C.unfold "A:12\r\n\t34" with
  | Ok [ "A:1234" ] -> ()
  | _ -> fail "HTAB fold must rejoin"

let test_unfold_orphan_continuation () =
  match C.unfold " orphan" with
  | Error (C.Orphan_continuation { line = 1 }) -> ()
  | _ -> fail "leading continuation must be rejected"

let test_unfold_skips_empty_lines () =
  match C.unfold "A:1\r\n\r\nB:2\r\n" with
  | Ok [ "A:1"; "B:2" ] -> ()
  | _ -> fail "empty physical lines must be skipped"

(* ---------------------------------------------------------------- *)
(* Parse                                                            *)
(* ---------------------------------------------------------------- *)

let test_parse_simple () =
  let cl = parse_ok "UID:12345@example.com" in
  check string "name" "UID" cl.C.name;
  check string "value" "12345@example.com" cl.C.value;
  check int "no params" 0 (List.length cl.C.params)

let test_parse_name_uppercased () =
  let cl = parse_ok "dtstart:19980118T230000" in
  check string "name" "DTSTART" cl.C.name

let test_parse_params () =
  let cl = parse_ok "RDATE;VALUE=DATE:19970304,19970504" in
  check string "name" "RDATE" cl.C.name;
  (match cl.C.params with
   | [ { C.name; values } ] ->
     check string "param name" "VALUE" name;
     check bool "values" true (values = [ "DATE" ])
   | _ -> fail "expected one param");
  check string "value" "19970304,19970504" cl.C.value

let test_parse_multi_value_param () =
  let cl = parse_ok "ATTENDEE;MEMBER=a,b,c:x" in
  match cl.C.params with
  | [ { C.values; _ } ] ->
    check bool "three values" true (values = [ "a"; "b"; "c" ])
  | _ -> fail "expected one param"

let test_parse_quoted_param_protects_separators () =
  (* [;] [:] [,] inside a quoted param value must not split. *)
  let cl = parse_ok "DESCRIPTION;ALTREP=\"cid:part1,0001@example.org\":Fall" in
  (match cl.C.params with
   | [ { C.name; values } ] ->
     check string "param name" "ALTREP" name;
     check bool "quoted value" true (values = [ "cid:part1,0001@example.org" ])
   | _ -> fail "expected one param");
  check string "value" "Fall" cl.C.value

let test_parse_semicolon_in_quoted_param () =
  let cl = parse_ok "X-PROP;X-P=\"a;b\":v" in
  match cl.C.params with
  | [ { C.values; _ } ] -> check bool "semicolon kept" true (values = [ "a;b" ])
  | _ -> fail "expected one param"

let test_parse_multiple_params () =
  let cl = parse_ok "DTSTART;TZID=America/New_York;VALUE=DATE-TIME:19980119T020000" in
  check int "two params" 2 (List.length cl.C.params);
  (match C.find_param ~name:"tzid" cl.C.params with
   | Some { C.values = [ "America/New_York" ]; _ } -> ()
   | _ -> fail "TZID param lookup failed");
  check string "value" "19980119T020000" cl.C.value

let test_parse_value_may_contain_colon () =
  let cl = parse_ok "URL:http://example.com/path" in
  check string "value" "http://example.com/path" cl.C.value

let test_parse_missing_colon () =
  match parse_error "NO-COLON-HERE" with
  | C.Missing_colon { line = 1 } -> ()
  | e -> failf "wrong error: %s" (C.parse_error_to_string e)

let test_parse_empty_name () =
  match parse_error ":value" with
  | C.Empty_name _ -> ()
  | e -> failf "wrong error: %s" (C.parse_error_to_string e)

let test_parse_invalid_name_char () =
  match parse_error "BAD NAME:x" with
  | C.Invalid_name_char _ -> ()
  | e -> failf "wrong error: %s" (C.parse_error_to_string e)

let test_parse_param_missing_equals () =
  match parse_error "PROP;PARAM:x" with
  | C.Missing_param_equals _ -> ()
  | e -> failf "wrong error: %s" (C.parse_error_to_string e)

let test_parse_unterminated_quote () =
  (* A quote that opens and never closes swallows the value separator, so
     the accurate diagnosis is the missing colon. A closed quote followed by
     junk is the unterminated/malformed quoted-string case. *)
  match parse_error "PROP;P=\"abc\"def:x" with
  | C.Unterminated_quoted_string _ -> ()
  | e -> failf "wrong error: %s" (C.parse_error_to_string e)

let test_parse_open_quote_hides_colon () =
  match parse_error "PROP;P=\"unterminated:x" with
  | C.Missing_colon _ -> ()
  | e -> failf "wrong error: %s" (C.parse_error_to_string e)

let test_parse_control_character () =
  match parse_error "A:has\001control" with
  | C.Control_character _ -> ()
  | e -> failf "wrong error: %s" (C.parse_error_to_string e)

let test_parse_utf8_value_allowed () =
  let cl = parse_ok "SUMMARY:한국어 제목" in
  check string "utf8 kept" "한국어 제목" cl.C.value

(* ---------------------------------------------------------------- *)
(* parse_many                                                       *)
(* ---------------------------------------------------------------- *)

let test_parse_many_tracks_physical_lines () =
  let input = "A:1\r\n fold\r\nB:x\r\n" in
  match C.parse_many input with
  | Ok [ a; b ] ->
    check string "a" "A" a.C.name;
    (* §3.1: the CRLF and the continuation's leading whitespace are both
       removed, so "1" + "fold" joins with no space. *)
    check string "a folded" "1fold" a.C.value;
    check string "b" "B" b.C.name
  | Ok other -> failf "expected 2 lines, got %d" (List.length other)
  | Error e -> fail (C.parse_error_to_string e)

let test_parse_many_error_line_number () =
  match C.parse_many "A:1\r\nB:2\r\nNOPE\r\n" with
  | Error (C.Missing_colon { line = 3 }) -> ()
  | Error e -> failf "wrong error: %s" (C.parse_error_to_string e)
  | Ok _ -> fail "must reject"

let () =
  run "Schedule_ical_content_line"
    [ "unfold"
      , [ test_case "crlf basic" `Quick test_unfold_crlf_basic
        ; test_case "bare lf accepted" `Quick test_unfold_bare_lf_accepted
        ; test_case "lone cr rejected" `Quick test_unfold_lone_cr_rejected
        ; test_case "folding rejoins" `Quick test_unfold_folding_rejoins
        ; test_case "folding tab" `Quick test_unfold_folding_tab
        ; test_case "orphan continuation" `Quick
            test_unfold_orphan_continuation
        ; test_case "empty lines skipped" `Quick test_unfold_skips_empty_lines
        ]
    ; "parse"
      , [ test_case "simple" `Quick test_parse_simple
        ; test_case "name uppercased" `Quick test_parse_name_uppercased
        ; test_case "params" `Quick test_parse_params
        ; test_case "multi value param" `Quick test_parse_multi_value_param
        ; test_case "quoted param protects separators" `Quick
            test_parse_quoted_param_protects_separators
        ; test_case "semicolon in quoted param" `Quick
            test_parse_semicolon_in_quoted_param
        ; test_case "multiple params" `Quick test_parse_multiple_params
        ; test_case "value may contain colon" `Quick
            test_parse_value_may_contain_colon
        ; test_case "missing colon" `Quick test_parse_missing_colon
        ; test_case "empty name" `Quick test_parse_empty_name
        ; test_case "invalid name char" `Quick test_parse_invalid_name_char
        ; test_case "param missing equals" `Quick
            test_parse_param_missing_equals
        ; test_case "unterminated quote" `Quick test_parse_unterminated_quote
        ; test_case "open quote hides colon" `Quick
            test_parse_open_quote_hides_colon
        ; test_case "control character" `Quick test_parse_control_character
        ; test_case "utf8 value allowed" `Quick test_parse_utf8_value_allowed
        ]
    ; "parse_many"
      , [ test_case "tracks physical lines" `Quick
            test_parse_many_tracks_physical_lines
        ; test_case "error line number" `Quick
            test_parse_many_error_line_number
        ]
    ]
