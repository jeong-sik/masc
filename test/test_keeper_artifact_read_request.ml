(** Per-field diagnostics for [keeper_artifact_read] request parsing.

    Live failure 2026-08-05 20:06:36:
    [{"max_bytes": 565244, "offset": 0, "sha256": "8ee32b2a…740c"}] was
    answered with ["expected sha256, non-negative offset, and max_bytes
    1..65536"]. The sha256 was correct; [max_bytes] was over the maximum.
    One catch-all served seven distinct causes and named the innocent field
    first.

    These tests pin two things: every rejection now names the field that
    actually failed, and the accept/reject decision itself is unchanged —
    the same inputs are still accepted and still rejected. *)

module R = Masc.Keeper_artifact_read

let production_max_bytes = 565_244
let production_sha256 = "8ee32b2a47387c0d0f7d30f93f476843c0a1e8804907d83aacd7a3ebf5c8740c"
let valid_sha256 = String.make 64 'a'

let string_contains haystack needle =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in
  if needle_length > haystack_length
  then false
  else (
    let found = ref false in
    for index = 0 to haystack_length - needle_length do
      if (not !found) && String.equal (String.sub haystack index needle_length) needle
      then found := true
    done;
    !found)
;;

let message_of_rejection ~label json =
  match R.For_testing.request_of_json json with
  | Ok _ -> Alcotest.failf "%s: expected a rejection, got an accepted request" label
  | Error invalid -> R.invalid_request_to_string invalid
;;

let check_names ~label ~message needles =
  List.iter
    (fun needle ->
       Alcotest.(check bool)
         (Printf.sprintf "%s names %S" label needle)
         true
         (string_contains message needle))
    needles
;;

let check_omits ~label ~message needles =
  List.iter
    (fun needle ->
       Alcotest.(check bool)
         (Printf.sprintf "%s must not mention %S (got: %s)" label needle message)
         false
         (string_contains message needle))
    needles
;;

(* --- The exact production request --------------------------------- *)

let test_production_case_names_max_bytes () =
  let message =
    message_of_rejection
      ~label:"production artifact read"
      (`Assoc
        [ "max_bytes", `Int production_max_bytes
        ; "offset", `Int 0
        ; "sha256", `String production_sha256
        ])
  in
  check_names
    ~label:"production artifact read"
    ~message
    [ "max_bytes"
    ; string_of_int production_max_bytes
    ; string_of_int R.maximum_max_bytes
    ];
  check_omits ~label:"production artifact read" ~message [ "sha256" ]
;;

(* A correct sha256 must never appear in the diagnosis, whatever else is
   wrong with the request. *)
let test_valid_sha256_never_blamed () =
  List.iter
    (fun (label, args) ->
       let message = message_of_rejection ~label args in
       check_omits ~label ~message [ "sha256" ])
    [ ( "max_bytes over maximum"
      , `Assoc
          [ "sha256", `String valid_sha256; "max_bytes", `Int production_max_bytes ] )
    ; ( "max_bytes under minimum"
      , `Assoc [ "sha256", `String valid_sha256; "max_bytes", `Int 0 ] )
    ; "negative offset", `Assoc [ "sha256", `String valid_sha256; "offset", `Int (-1) ]
    ; ( "offset of the wrong type"
      , `Assoc [ "sha256", `String valid_sha256; "offset", `String "0" ] )
    ]
;;

(* --- One test per distinct rejection cause ------------------------- *)

let test_max_bytes_above_maximum () =
  let message =
    message_of_rejection
      ~label:"max_bytes above maximum"
      (`Assoc
        [ "sha256", `String valid_sha256
        ; "max_bytes", `Int (R.maximum_max_bytes + 1)
        ])
  in
  Alcotest.(check string)
    "max_bytes above maximum"
    (Printf.sprintf
       "max_bytes %d exceeds maximum %d"
       (R.maximum_max_bytes + 1)
       R.maximum_max_bytes)
    message
;;

let test_max_bytes_below_minimum () =
  let message =
    message_of_rejection
      ~label:"max_bytes below minimum"
      (`Assoc
        [ "sha256", `String valid_sha256
        ; "max_bytes", `Int (R.minimum_max_bytes - 1)
        ])
  in
  Alcotest.(check string)
    "max_bytes below minimum"
    (Printf.sprintf
       "max_bytes %d is below minimum %d"
       (R.minimum_max_bytes - 1)
       R.minimum_max_bytes)
    message
;;

let test_offset_below_minimum () =
  let message =
    message_of_rejection
      ~label:"negative offset"
      (`Assoc [ "sha256", `String valid_sha256; "offset", `Int (-1) ])
  in
  Alcotest.(check string)
    "negative offset"
    (Printf.sprintf "offset -1 is below minimum %d" R.minimum_offset)
    message
;;

let test_offset_wrong_type () =
  let message =
    message_of_rejection
      ~label:"offset of the wrong type"
      (`Assoc [ "sha256", `String valid_sha256; "offset", `String "0" ])
  in
  Alcotest.(check string)
    "offset of the wrong type"
    "offset must be an integer, got string"
    message
;;

let test_max_bytes_wrong_type () =
  let message =
    message_of_rejection
      ~label:"max_bytes of the wrong type"
      (`Assoc [ "sha256", `String valid_sha256; "max_bytes", `Bool true ])
  in
  Alcotest.(check string)
    "max_bytes of the wrong type"
    "max_bytes must be an integer, got bool"
    message
;;

(* [Yojson.Safe] parses an integer literal wider than a native [int] into
   [`Intlit]. The old parser swept it into the catch-all; it is still
   rejected, but under its own name. *)
let test_max_bytes_out_of_native_int_range () =
  let literal = "99999999999999999999999999" in
  let message =
    message_of_rejection
      ~label:"max_bytes wider than a native int"
      (`Assoc [ "sha256", `String valid_sha256; "max_bytes", `Intlit literal ])
  in
  Alcotest.(check string)
    "max_bytes wider than a native int"
    (Printf.sprintf
       "max_bytes integer literal %s is outside the native integer range"
       literal)
    message
;;

let test_offset_unparsed_integer_literal () =
  let message =
    message_of_rejection
      ~label:"offset as an unparsed integer literal"
      (`Assoc [ "sha256", `String valid_sha256; "offset", `Intlit "7" ])
  in
  Alcotest.(check string)
    "offset as an unparsed integer literal"
    "offset must be a JSON integer, got the unparsed integer literal 7"
    message
;;

let test_sha256_missing () =
  let message =
    message_of_rejection ~label:"sha256 missing" (`Assoc [ "offset", `Int 0 ])
  in
  Alcotest.(check string) "sha256 missing" "sha256 is required" message
;;

let test_sha256_wrong_type () =
  let message =
    message_of_rejection ~label:"sha256 of the wrong type" (`Assoc [ "sha256", `Int 5 ])
  in
  Alcotest.(check string)
    "sha256 of the wrong type"
    "sha256 must be a string, got int"
    message
;;

let test_sha256_malformed () =
  let message =
    message_of_rejection
      ~label:"sha256 malformed"
      (`Assoc [ "sha256", `String (String.make 63 'a') ])
  in
  check_names ~label:"sha256 malformed" ~message [ "sha256"; "63" ]
;;

let test_not_an_object () =
  let message = message_of_rejection ~label:"array payload" (`List []) in
  Alcotest.(check string) "array payload" "expected an object, got array" message
;;

(* --- Accept/reject parity ------------------------------------------ *)

(** The decision the parser made before per-field diagnostics existed,
    transcribed from the pre-change [request_of_json]. The rewrite may only
    change the message, never which requests are served. *)
let legacy_accepts (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    let sha256 =
      match List.assoc_opt "sha256" fields with
      | Some (`String value) -> Some value
      | _ -> None
    in
    let offset =
      match List.assoc_opt "offset" fields with
      | None -> Some 0
      | Some (`Int value) -> Some value
      | _ -> None
    in
    let max_bytes =
      match List.assoc_opt "max_bytes" fields with
      | None -> Some R.default_max_bytes
      | Some (`Int value) -> Some value
      | _ -> None
    in
    (match sha256, offset, max_bytes with
     | Some sha256, Some offset, Some max_bytes
       when offset >= 0
            && max_bytes >= R.minimum_max_bytes
            && max_bytes <= R.maximum_max_bytes ->
       (match Tool_output.validate_sha256 sha256 with
        | Ok () -> true
        | Error _ -> false)
     | _ -> false)
  | _ -> false
;;

let parity_cases : (string * Yojson.Safe.t) list =
  [ "minimal valid", `Assoc [ "sha256", `String valid_sha256 ]
  ; "production sha256 with defaults", `Assoc [ "sha256", `String production_sha256 ]
  ; ( "valid with explicit bounds"
      , `Assoc
          [ "sha256", `String valid_sha256
          ; "offset", `Int 0
          ; "max_bytes", `Int R.maximum_max_bytes
          ] )
    ; ( "max_bytes at minimum"
      , `Assoc
          [ "sha256", `String valid_sha256
          ; "max_bytes", `Int R.minimum_max_bytes
          ] )
    ; ( "max_bytes one over maximum"
      , `Assoc
          [ "sha256", `String valid_sha256
          ; "max_bytes", `Int (R.maximum_max_bytes + 1)
          ] )
    ; ( "production request"
      , `Assoc
          [ "max_bytes", `Int production_max_bytes
          ; "offset", `Int 0
          ; "sha256", `String production_sha256
          ] )
    ; ( "max_bytes zero"
      , `Assoc [ "sha256", `String valid_sha256; "max_bytes", `Int 0 ] )
    ; ( "negative offset"
      , `Assoc [ "sha256", `String valid_sha256; "offset", `Int (-1) ] )
    ; ( "large but in-range offset"
      , `Assoc [ "sha256", `String valid_sha256; "offset", `Int 1_000_000 ] )
    ; ( "offset as a string"
      , `Assoc [ "sha256", `String valid_sha256; "offset", `String "0" ] )
    ; ( "offset as an integer literal"
      , `Assoc [ "sha256", `String valid_sha256; "offset", `Intlit "7" ] )
    ; ( "max_bytes as an oversized integer literal"
      , `Assoc
          [ "sha256", `String valid_sha256
          ; "max_bytes", `Intlit "99999999999999999999999999"
          ] )
    ; ( "max_bytes as a float"
      , `Assoc [ "sha256", `String valid_sha256; "max_bytes", `Float 1024.0 ] )
    ; ( "max_bytes null"
      , `Assoc [ "sha256", `String valid_sha256; "max_bytes", `Null ] )
    ; "sha256 missing", `Assoc [ "offset", `Int 0 ]
    ; "sha256 null", `Assoc [ "sha256", `Null ]
    ; "sha256 as an integer", `Assoc [ "sha256", `Int 5 ]
    ; "sha256 too short", `Assoc [ "sha256", `String (String.make 63 'a') ]
    ; "sha256 too long", `Assoc [ "sha256", `String (String.make 65 'a') ]
    ; "sha256 uppercase", `Assoc [ "sha256", `String (String.make 64 'A') ]
    ; "empty object", `Assoc []
    ; "array payload", `List []
    ; "string payload", `String valid_sha256
    ; "null payload", `Null
    ; ( "everything wrong at once"
      , `Assoc
          [ "sha256", `String "nope"
          ; "offset", `Int (-5)
          ; "max_bytes", `Int production_max_bytes
          ] )
    ]
;;

let test_accept_reject_set_is_unchanged () =
  List.iter
    (fun (label, args) ->
       let accepted =
         match R.For_testing.request_of_json args with
         | Ok _ -> true
         | Error _ -> false
       in
       Alcotest.(check bool)
         (Printf.sprintf "accept/reject unchanged for %s" label)
         (legacy_accepts args)
         accepted)
    parity_cases
;;

(* An accepted request must still carry the values it was given, including
   the documented defaults for omitted fields. *)
let test_accepted_request_fields () =
  match
    R.For_testing.request_of_json
      (`Assoc [ "sha256", `String production_sha256; "max_bytes", `Int 1024 ])
  with
  | Error invalid ->
    Alcotest.failf
      "expected an in-range request to parse, got %s"
      (R.invalid_request_to_string invalid)
  | Ok request ->
    Alcotest.(check string) "sha256" production_sha256 request.sha256;
    Alcotest.(check int) "offset defaults to the minimum" R.minimum_offset request.offset;
    Alcotest.(check int) "max_bytes" 1024 request.max_bytes
;;

let test_defaults_when_only_sha256_is_given () =
  match R.For_testing.request_of_json (`Assoc [ "sha256", `String valid_sha256 ]) with
  | Error invalid ->
    Alcotest.failf
      "expected a sha256-only request to parse, got %s"
      (R.invalid_request_to_string invalid)
  | Ok request ->
    Alcotest.(check int) "offset default" R.minimum_offset request.offset;
    Alcotest.(check int) "max_bytes default" R.default_max_bytes request.max_bytes
;;

let () =
  Alcotest.run
    "keeper_artifact_read_request"
    [ ( "field_named_rejections"
      , [ Alcotest.test_case "production max_bytes names max_bytes" `Quick
            test_production_case_names_max_bytes
        ; Alcotest.test_case "a valid sha256 is never blamed" `Quick
            test_valid_sha256_never_blamed
        ; Alcotest.test_case "max_bytes above maximum" `Quick
            test_max_bytes_above_maximum
        ; Alcotest.test_case "max_bytes below minimum" `Quick
            test_max_bytes_below_minimum
        ; Alcotest.test_case "offset below minimum" `Quick test_offset_below_minimum
        ; Alcotest.test_case "offset of the wrong type" `Quick test_offset_wrong_type
        ; Alcotest.test_case "max_bytes of the wrong type" `Quick
            test_max_bytes_wrong_type
        ; Alcotest.test_case "max_bytes wider than a native int" `Quick
            test_max_bytes_out_of_native_int_range
        ; Alcotest.test_case "offset as an unparsed integer literal" `Quick
            test_offset_unparsed_integer_literal
        ; Alcotest.test_case "sha256 missing" `Quick test_sha256_missing
        ; Alcotest.test_case "sha256 of the wrong type" `Quick test_sha256_wrong_type
        ; Alcotest.test_case "sha256 malformed" `Quick test_sha256_malformed
        ; Alcotest.test_case "payload is not an object" `Quick test_not_an_object
        ] )
    ; ( "decision_parity"
      , [ Alcotest.test_case "accept/reject set is unchanged" `Quick
            test_accept_reject_set_is_unchanged
        ; Alcotest.test_case "accepted request keeps its fields" `Quick
            test_accepted_request_fields
        ; Alcotest.test_case "omitted fields take their defaults" `Quick
            test_defaults_when_only_sha256_is_given
        ] )
    ]
;;
