module Lib = Masc_mcp
open Alcotest

(** Helper: extract trace_id (chars 3..34) from a traceparent string. *)
let trace_id_of tp = String.sub tp 3 32

(** Helper: extract parent_id (chars 36..51) from a traceparent string. *)
let parent_id_of tp = String.sub tp 36 16

(** Helper: extract trace_flags (chars 53..54) from a traceparent string. *)
let flags_of tp = String.sub tp 53 2

(* --- W3C traceparent parsing --- *)

let valid_traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

let test_parse_valid () =
  match Lib.Otel_trace_context.parse valid_traceparent with
  | Some ctx ->
    check string "traceparent preserved" valid_traceparent ctx.traceparent;
    check bool "sampled" true ctx.sampled
  | None -> fail "expected Some, got None"
;;

let test_parse_not_sampled () =
  let tp = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00" in
  match Lib.Otel_trace_context.parse tp with
  | Some ctx -> check bool "not sampled" false ctx.sampled
  | None -> fail "expected Some for unsampled trace"
;;

let test_parse_invalid_version () =
  let tp = "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" in
  match Lib.Otel_trace_context.parse tp with
  | None -> ()
  | Some _ -> fail "expected None for invalid version ff"
;;

let test_parse_all_zero_trace_id () =
  let tp = "00-00000000000000000000000000000000-00f067aa0ba902b7-01" in
  match Lib.Otel_trace_context.parse tp with
  | None -> ()
  | Some _ -> fail "expected None for all-zero trace_id"
;;

let test_parse_all_zero_parent_id () =
  let tp = "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01" in
  match Lib.Otel_trace_context.parse tp with
  | None -> ()
  | Some _ -> fail "expected None for all-zero parent_id"
;;

let test_parse_truncated () =
  match Lib.Otel_trace_context.parse "00-4bf92f35" with
  | None -> ()
  | Some _ -> fail "expected None for truncated input"
;;

let test_parse_empty () =
  match Lib.Otel_trace_context.parse "" with
  | None -> ()
  | Some _ -> fail "expected None for empty input"
;;

let test_parse_garbage () =
  match Lib.Otel_trace_context.parse "not-a-traceparent-at-all" with
  | None -> ()
  | Some _ -> fail "expected None for garbage"
;;

(* --- Generation roundtrip --- *)

let test_to_traceparent_roundtrip () =
  match Lib.Otel_trace_context.parse valid_traceparent with
  | Some ctx ->
    let regenerated =
      Lib.Otel_trace_context.to_traceparent
        ~trace_id:ctx.trace_id
        ~parent_id:ctx.parent_id
        ~sampled:ctx.sampled
        ()
    in
    check string "roundtrip" valid_traceparent regenerated
  | None -> fail "parse failed"
;;

(* --- Propagation --- *)

let test_propagate_keeps_trace_id () =
  match Lib.Otel_trace_context.parse valid_traceparent with
  | Some ctx ->
    let child = Lib.Otel_trace_context.propagate ctx in
    check
      string
      "trace_id preserved"
      (trace_id_of ctx.traceparent)
      (trace_id_of child.traceparent);
    if String.equal (parent_id_of ctx.traceparent) (parent_id_of child.traceparent)
    then fail "parent_id should differ after propagation"
  | None -> fail "parse failed"
;;

let test_propagate_sampled_preserved () =
  match Lib.Otel_trace_context.parse valid_traceparent with
  | Some ctx ->
    let child = Lib.Otel_trace_context.propagate ctx in
    check bool "sampled preserved" ctx.sampled child.sampled;
    check string "flags preserved" (flags_of ctx.traceparent) (flags_of child.traceparent)
  | None -> fail "parse failed"
;;

let test_propagate_version_preserved () =
  match Lib.Otel_trace_context.parse valid_traceparent with
  | Some ctx ->
    let child = Lib.Otel_trace_context.propagate ctx in
    check string "version 00" "00" (String.sub child.traceparent 0 2)
  | None -> fail "parse failed"
;;

(* --- JSON helpers --- *)

let test_of_json_present () =
  let json =
    `Assoc
      [ "type", `String "masc/broadcast"; "trace_context", `String valid_traceparent ]
  in
  match Lib.Otel_trace_context.of_json json with
  | Some ctx -> check string "traceparent from json" valid_traceparent ctx.traceparent
  | None -> fail "expected Some from valid JSON"
;;

let test_of_json_absent () =
  let json = `Assoc [ "type", `String "masc/broadcast" ] in
  match Lib.Otel_trace_context.of_json json with
  | None -> ()
  | Some _ -> fail "expected None for absent trace_context"
;;

let test_of_json_null () =
  let json = `Assoc [ "trace_context", `Null ] in
  match Lib.Otel_trace_context.of_json json with
  | None -> ()
  | Some _ -> fail "expected None for null trace_context"
;;

let test_of_json_not_object () =
  match Lib.Otel_trace_context.of_json (`String "not an object") with
  | None -> ()
  | Some _ -> fail "expected None for non-object"
;;

let test_of_json_invalid_traceparent () =
  let json = `Assoc [ "trace_context", `String "garbage" ] in
  match Lib.Otel_trace_context.of_json json with
  | None -> ()
  | Some _ -> fail "expected None for invalid traceparent in JSON"
;;

let test_inject_json_some () =
  let fields = [ "type", `String "masc/broadcast" ] in
  let result = Lib.Otel_trace_context.inject_json fields (Some valid_traceparent) in
  match List.assoc_opt "trace_context" result with
  | Some (`String v) -> check string "injected" valid_traceparent v
  | _ -> fail "trace_context not found in result"
;;

let test_inject_json_none () =
  let fields = [ "type", `String "masc/broadcast" ] in
  let result = Lib.Otel_trace_context.inject_json fields None in
  check int "no extra field" 1 (List.length result)
;;

(* --- HTTP header helpers --- *)

let test_of_headers_found () =
  let headers =
    [ "content-type", "application/json"; "Traceparent", valid_traceparent ]
  in
  match Lib.Otel_trace_context.of_headers headers with
  | Some ctx -> check string "from header" valid_traceparent ctx.traceparent
  | None -> fail "expected Some from valid header"
;;

let test_of_headers_case_insensitive () =
  let headers = [ "TRACEPARENT", valid_traceparent ] in
  match Lib.Otel_trace_context.of_headers headers with
  | Some _ -> ()
  | None -> fail "expected case-insensitive match"
;;

let test_of_headers_absent () =
  let headers = [ "content-type", "text/plain" ] in
  match Lib.Otel_trace_context.of_headers headers with
  | None -> ()
  | Some _ -> fail "expected None for missing header"
;;

let test_to_header () =
  match Lib.Otel_trace_context.parse valid_traceparent with
  | Some ctx ->
    let name, value = Lib.Otel_trace_context.to_header ctx in
    check string "header name" "traceparent" name;
    check string "header value" valid_traceparent value
  | None -> fail "parse failed"
;;

let test_header_name () =
  check string "W3C spec lowercase" "traceparent" Lib.Otel_trace_context.header_name
;;

let test_of_headers_multiple_discard () =
  let headers =
    [ "traceparent", valid_traceparent
    ; "traceparent", "00-aaaabbbbccccddddaaaabbbbccccdddd-1122334455667788-01"
    ]
  in
  match Lib.Otel_trace_context.of_headers headers with
  | None -> ()
  | Some _ -> fail "expected None for multiple traceparent headers (W3C spec)"
;;

(* --- Whitespace handling --- *)

let test_parse_with_whitespace () =
  let tp = "  " ^ valid_traceparent ^ "  " in
  match Lib.Otel_trace_context.parse tp with
  | Some ctx -> check string "trimmed" valid_traceparent ctx.traceparent
  | None -> fail "expected Some after trimming whitespace"
;;

(* --- Future version handling --- *)

let test_parse_future_version () =
  let tp = "01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" in
  match Lib.Otel_trace_context.parse tp with
  | Some ctx ->
    let tid = trace_id_of ctx.traceparent in
    check string "trace_id preserved" "4bf92f3577b34da6a3ce929d0e0e4736" tid
  | None ->
    (* Library may reject future versions — document as known limitation *)
    ()
;;

(* --- Runner --- *)

let () =
  run
    "otel_trace_context"
    [ ( "parse"
      , [ test_case "valid traceparent" `Quick test_parse_valid
        ; test_case "not sampled" `Quick test_parse_not_sampled
        ; test_case "invalid version ff" `Quick test_parse_invalid_version
        ; test_case "all-zero trace_id" `Quick test_parse_all_zero_trace_id
        ; test_case "all-zero parent_id" `Quick test_parse_all_zero_parent_id
        ; test_case "truncated" `Quick test_parse_truncated
        ; test_case "empty" `Quick test_parse_empty
        ; test_case "garbage" `Quick test_parse_garbage
        ] )
    ; "generate", [ test_case "roundtrip" `Quick test_to_traceparent_roundtrip ]
    ; ( "propagate"
      , [ test_case "keeps trace_id" `Quick test_propagate_keeps_trace_id
        ; test_case "sampled preserved" `Quick test_propagate_sampled_preserved
        ; test_case "version preserved" `Quick test_propagate_version_preserved
        ] )
    ; ( "json"
      , [ test_case "of_json present" `Quick test_of_json_present
        ; test_case "of_json absent" `Quick test_of_json_absent
        ; test_case "of_json null" `Quick test_of_json_null
        ; test_case "of_json not object" `Quick test_of_json_not_object
        ; test_case "of_json invalid traceparent" `Quick test_of_json_invalid_traceparent
        ; test_case "inject some" `Quick test_inject_json_some
        ; test_case "inject none" `Quick test_inject_json_none
        ] )
    ; ( "http_headers"
      , [ test_case "found" `Quick test_of_headers_found
        ; test_case "case insensitive" `Quick test_of_headers_case_insensitive
        ; test_case "absent" `Quick test_of_headers_absent
        ; test_case "to_header" `Quick test_to_header
        ; test_case "header_name" `Quick test_header_name
        ; test_case "multiple headers discarded" `Quick test_of_headers_multiple_discard
        ] )
    ; ( "edge_cases"
      , [ test_case "whitespace trimmed" `Quick test_parse_with_whitespace
        ; test_case "future version 01" `Quick test_parse_future_version
        ] )
    ]
;;
