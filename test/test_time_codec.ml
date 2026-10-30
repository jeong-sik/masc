open Alcotest

let check_timestamp label expected input =
  match Time_codec.parse_rfc3339 input with
  | Error Time_codec.Invalid_rfc3339 -> fail (label ^ ": expected valid RFC 3339")
  | Ok actual -> check (float 0.000_001) label expected actual
;;

let check_invalid ?(strict = true) label input =
  match Time_codec.parse_rfc3339 ~strict input with
  | Error Time_codec.Invalid_rfc3339 -> ()
  | Ok timestamp ->
    failf "%s: expected rejection, received %.6f" label timestamp
;;

let test_epoch () = check_timestamp "epoch" 0.0 "1970-01-01T00:00:00Z"

let test_fraction_preserved () =
  check_timestamp "fraction" 0.125 "1970-01-01T00:00:00.125Z"
;;

let test_offset_normalized () =
  check_timestamp "offset" 0.0 "1970-01-01T09:00:00+09:00"
;;

let test_whole_seconds_truncates_before_float_conversion () =
  match
    Time_codec.parse_rfc3339_whole_seconds
      "2099-01-02T09:00:00.999999999999+09:00"
  with
  | Error Time_codec.Invalid_rfc3339 -> fail "expected valid RFC 3339 timestamp"
  | Ok actual ->
    (match Time_codec.parse_rfc3339 "2099-01-02T00:00:00Z" with
     | Error Time_codec.Invalid_rfc3339 -> fail "expected valid whole-second reference"
     | Ok expected -> check (float 0.0) "fraction truncated exactly" expected actual)
;;

let test_invalid_civil_date_rejected () =
  check_invalid "February 31 is invalid" "2026-02-31T12:00:00Z"
;;

let test_invalid_offset_rejected () =
  check_invalid "offset bounds" "2026-04-08T12:38:15+99:99"
;;

let test_bare_local_rejected () =
  check_invalid "timezone is required" "2026-04-08T12:38:15"
;;

let test_compact_offset_requires_explicit_compatibility () =
  let input = "1970-01-01T09:00:00+0900" in
  check_invalid "strict rejects compact offset" input;
  match Time_codec.parse_rfc3339 ~strict:false input with
  | Error Time_codec.Invalid_rfc3339 -> fail "compatibility mode should accept +0900"
  | Ok actual -> check (float 0.000_001) "compact offset" 0.0 actual
;;

let test_rfc3339_of_unix_ms_shape () =
  (* The shape the sub-second callers used to
     spell out by hand. *)
  let t = 1_787_803_506.789 in
  Alcotest.(check string)
    "millisecond form"
    "2026-08-27T04:05:06.789Z"
    (Time_codec.rfc3339_of_unix_ms t)
;;

let test_rfc3339_of_unix_ms_agrees_on_whole_seconds () =
  let t = 1_787_803_506.0 in
  let whole = Time_codec.rfc3339_of_unix t in
  let with_ms = Time_codec.rfc3339_of_unix_ms t in
  Alcotest.(check string)
    "same prefix up to the seconds field"
    whole
    (String.sub with_ms 0 (String.length whole - 1) ^ "Z")
;;

let () =
  run
    "Time_codec"
    [ ( "RFC 3339"
      , [ test_case "epoch" `Quick test_epoch
        ; test_case "fraction preserved" `Quick test_fraction_preserved
        ; test_case "offset normalized" `Quick test_offset_normalized
        ; test_case
            "whole seconds truncate before float conversion"
            `Quick
            test_whole_seconds_truncates_before_float_conversion
        ; test_case "invalid civil date rejected" `Quick test_invalid_civil_date_rejected
        ; test_case "invalid offset rejected" `Quick test_invalid_offset_rejected
        ; test_case "bare local rejected" `Quick test_bare_local_rejected
        ; test_case
            "compact offset is explicit compatibility"
            `Quick
            test_compact_offset_requires_explicit_compatibility
        ] )
    ; ( "rfc3339 writer"
      , [ test_case "millisecond shape" `Quick test_rfc3339_of_unix_ms_shape
        ; test_case
            "agrees with the whole-second writer"
            `Quick
            test_rfc3339_of_unix_ms_agrees_on_whole_seconds
        ] )
    ]
;;
