(** Field-level validation feedback tests.
    Verifies Tool_args structured field_error responses. *)

open Alcotest
open Masc_mcp

let check_field_error msg (e : Tool_args.field_error) ~field ~constraint_s =
  check string (msg ^ " field") field e.field;
  check
    string
    (msg ^ " constraint")
    constraint_s
    (Tool_args.field_constraint_to_string e.constraint_violated)
;;

(* -- validate_string_required ------------------------------------------- *)

let test_string_required_ok () =
  let args = `Assoc [ "name", `String "alice" ] in
  match Tool_args.validate_string_required args "name" with
  | Ok v -> check string "trimmed value" "alice" v
  | Error _ -> fail "expected Ok"
;;

let test_string_required_trims () =
  let args = `Assoc [ "name", `String "  bob  " ] in
  match Tool_args.validate_string_required args "name" with
  | Ok v -> check string "trimmed" "bob" v
  | Error _ -> fail "expected Ok"
;;

let test_string_required_missing () =
  let args = `Assoc [] in
  match Tool_args.validate_string_required args "name" with
  | Ok _ -> fail "expected Error"
  | Error e -> check_field_error "missing" e ~field:"name" ~constraint_s:"required"
;;

let test_string_required_empty () =
  let args = `Assoc [ "name", `String "" ] in
  match Tool_args.validate_string_required args "name" with
  | Ok _ -> fail "expected Error"
  | Error e -> check_field_error "empty" e ~field:"name" ~constraint_s:"non_empty"
;;

let test_string_required_whitespace_only () =
  let args = `Assoc [ "name", `String "   " ] in
  match Tool_args.validate_string_required args "name" with
  | Ok _ -> fail "expected Error"
  | Error e -> check_field_error "whitespace" e ~field:"name" ~constraint_s:"non_empty"
;;

(* -- validate_int_required ---------------------------------------------- *)

let test_int_required_ok () =
  let args = `Assoc [ "count", `Int 42 ] in
  match Tool_args.validate_int_required args "count" with
  | Ok v -> check int "value" 42 v
  | Error _ -> fail "expected Ok"
;;

let test_int_required_missing () =
  let args = `Assoc [] in
  match Tool_args.validate_int_required args "count" with
  | Ok _ -> fail "expected Error"
  | Error e -> check_field_error "missing" e ~field:"count" ~constraint_s:"required"
;;

(* -- validate_int_range ------------------------------------------------- *)

let test_int_range_ok () =
  let args = `Assoc [ "priority", `Int 3 ] in
  match Tool_args.validate_int_range args "priority" ~min_v:1 ~max_v:5 ~default:2 with
  | Ok v -> check int "in range" 3 v
  | Error _ -> fail "expected Ok"
;;

let test_int_range_below_min () =
  let args = `Assoc [ "priority", `Int 0 ] in
  match Tool_args.validate_int_range args "priority" ~min_v:1 ~max_v:5 ~default:2 with
  | Ok _ -> fail "expected Error"
  | Error e ->
    check_field_error "below" e ~field:"priority" ~constraint_s:"min_int(1)";
    check (option string) "received" (Some "0") e.received
;;

let test_int_range_above_max () =
  let args = `Assoc [ "priority", `Int 10 ] in
  match Tool_args.validate_int_range args "priority" ~min_v:1 ~max_v:5 ~default:2 with
  | Ok _ -> fail "expected Error"
  | Error e -> check_field_error "above" e ~field:"priority" ~constraint_s:"max_int(5)"
;;

(* -- validate_one_of ---------------------------------------------------- *)

let test_one_of_ok () =
  let args = `Assoc [ "mode", `String "strict" ] in
  match
    Tool_args.validate_one_of
      args
      "mode"
      ~allowed:[ "strict"; "lenient" ]
      ~default:"strict"
  with
  | Ok v -> check string "value" "strict" v
  | Error _ -> fail "expected Ok"
;;

let test_one_of_rejected () =
  let args = `Assoc [ "mode", `String "yolo" ] in
  match
    Tool_args.validate_one_of
      args
      "mode"
      ~allowed:[ "strict"; "lenient" ]
      ~default:"strict"
  with
  | Ok _ -> fail "expected Error"
  | Error e ->
    check_field_error "rejected" e ~field:"mode" ~constraint_s:"one_of(strict,lenient)";
    check (option string) "received" (Some "yolo") e.received
;;

(* -- validate_all ------------------------------------------------------- *)

let test_validate_all_pass () =
  let results = [ Ok (); Ok (); Ok () ] in
  match Tool_args.validate_all results with
  | Ok () -> ()
  | Error _ -> fail "expected Ok"
;;

let test_validate_all_collects_errors () =
  let err1 : Tool_args.field_error =
    { field = "a"
    ; constraint_violated = Required
    ; message = "a required"
    ; expected = None
    ; received = None
    }
  in
  let err2 : Tool_args.field_error =
    { field = "b"
    ; constraint_violated = Non_empty
    ; message = "b empty"
    ; expected = None
    ; received = None
    }
  in
  let results = [ Error err1; Ok (); Error err2 ] in
  match Tool_args.validate_all results with
  | Ok () -> fail "expected Error"
  | Error errs ->
    check int "error count" 2 (List.length errs);
    check string "first field" "a" (List.hd errs).field;
    check string "second field" "b" (List.nth errs 1).field
;;

(* -- validation_error_response ------------------------------------------ *)

let test_response_json_shape () =
  let err : Tool_args.field_error =
    { field = "agent_id"
    ; constraint_violated = Required
    ; message = "agent_id is required"
    ; expected = Some "string"
    ; received = None
    }
  in
  let json_str = Tool_args.validation_error_response [ err ] in
  let json = Yojson.Safe.from_string json_str in
  let open Yojson.Safe.Util in
  check string "status" "error" (json |> member "status" |> to_string);
  check string "error_code" "validation_error" (json |> member "error_code" |> to_string);
  let field_errors = json |> member "field_errors" |> to_list in
  check int "field_errors length" 1 (List.length field_errors);
  let fe = List.hd field_errors in
  check string "fe.field" "agent_id" (fe |> member "field" |> to_string);
  check string "fe.constraint" "required" (fe |> member "constraint" |> to_string);
  check string "fe.expected" "string" (fe |> member "expected" |> to_string)
;;

(* -- Runner ------------------------------------------------------------- *)

let () =
  run
    ~and_exit:false
    "Field_validation"
    [ ( "string_required"
      , [ test_case "ok" `Quick test_string_required_ok
        ; test_case "trims whitespace" `Quick test_string_required_trims
        ; test_case "missing" `Quick test_string_required_missing
        ; test_case "empty" `Quick test_string_required_empty
        ; test_case "whitespace only" `Quick test_string_required_whitespace_only
        ] )
    ; ( "int_required"
      , [ test_case "ok" `Quick test_int_required_ok
        ; test_case "missing" `Quick test_int_required_missing
        ] )
    ; ( "int_range"
      , [ test_case "in range" `Quick test_int_range_ok
        ; test_case "below min" `Quick test_int_range_below_min
        ; test_case "above max" `Quick test_int_range_above_max
        ] )
    ; ( "one_of"
      , [ test_case "accepted" `Quick test_one_of_ok
        ; test_case "rejected" `Quick test_one_of_rejected
        ] )
    ; ( "validate_all"
      , [ test_case "all pass" `Quick test_validate_all_pass
        ; test_case "collects errors" `Quick test_validate_all_collects_errors
        ] )
    ; "response_shape", [ test_case "json structure" `Quick test_response_json_shape ]
    ]
;;
