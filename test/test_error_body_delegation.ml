(** Wire-shape assertions for RFC-0097 PR-2 delegation.

    Pins down the JSON body produced by {!error_body} (the SSOT
    introduced in PR-2) and documents the wire-byte change vs the
    pre-PR-2 baseline: error responses now carry [["id": null]] per
    JSON-RPC 2.0 §5.1, where the legacy hand-rolled bodies omitted
    the field. *)

open Alcotest
module R = Masc_mcp.Server_mcp_transport_http_respond
module C = Masc_mcp.Mcp_error_code

(* JSON equality with stable key order: compare normalised string
   forms. Yojson does not guarantee key order, but Yojson.Safe outputs
   keys in insertion order; both sides build the assoc in the same
   shape, so [Yojson.Safe.to_string] gives byte-comparable output. *)
let json_eq (a : Yojson.Safe.t) (b : Yojson.Safe.t) =
  Yojson.Safe.to_string a = Yojson.Safe.to_string b

let pp_json fmt j = Format.pp_print_string fmt (Yojson.Safe.to_string j)
let json_testable : Yojson.Safe.t Alcotest.testable = testable pp_json json_eq

let test_error_body_includes_id_null_by_default () =
  let body = R.error_body ~code:C.Internal_error "boom" in
  let expected =
    `Assoc
      [
        ("jsonrpc", `String "2.0");
        ("id", `Null);
        ( "error",
          `Assoc
            [
              ("code", `Int (-32603));
              ("message", `String "boom");
            ] );
      ]
  in
  check json_testable "id:null present per JSON-RPC 2.0 §5.1" expected body

let test_error_body_echoes_request_id () =
  let body =
    R.error_body ~id:(`Int 42) ~code:C.Method_not_found "no such method"
  in
  let expected =
    `Assoc
      [
        ("jsonrpc", `String "2.0");
        ("id", `Int 42);
        ( "error",
          `Assoc
            [
              ("code", `Int (-32601));
              ("message", `String "no such method");
            ] );
      ]
  in
  check json_testable "id echoes back when supplied" expected body

let test_error_body_includes_data_when_supplied () =
  let data = `Assoc [ ("provider", `String "anthropic"); ("budget_ms", `Int 30000) ] in
  let body =
    R.error_body ~data ~code:C.Provider_timeout "upstream stalled"
  in
  let expected =
    `Assoc
      [
        ("jsonrpc", `String "2.0");
        ("id", `Null);
        ( "error",
          `Assoc
            [
              ("code", `Int (-32003));
              ("message", `String "upstream stalled");
              ("data", data);
            ] );
      ]
  in
  check json_testable "data field included when supplied" expected body

let test_mcp_internal_error_json_now_typed () =
  (* The legacy [mcp_internal_error_json] is a thin delegation. It
     must produce the same wire bytes as [error_body
     ~code:Internal_error] — that is the PR-2 contract. *)
  let via_legacy = R.mcp_internal_error_json "explosion" in
  let via_ssot = R.error_body ~code:C.Internal_error "explosion" in
  check json_testable "mcp_internal_error_json == error_body Internal_error"
    via_ssot via_legacy

let test_mcp_internal_error_json_with_id () =
  let via_legacy = R.mcp_internal_error_json ~id:(`Int 7) "oops" in
  let via_ssot = R.error_body ~id:(`Int 7) ~code:C.Internal_error "oops" in
  check json_testable "mcp_internal_error_json ~id == error_body ~id"
    via_ssot via_legacy

let test_wire_byte_change_documented () =
  (* Documents the intentional wire-byte change introduced by PR-2:
     the response body now contains "id":null where it previously did
     not. This is a one-way contract change — bumping for spec
     compliance. *)
  let pr1_baseline_no_id =
    `Assoc
      [
        ("jsonrpc", `String "2.0");
        ( "error",
          `Assoc
            [
              ("code", `Int (-32001));
              ("message", `String "Unauthorized");
            ] );
      ]
  in
  let pr2_with_id_null = R.error_body ~code:C.Auth_error "Unauthorized" in
  let differ = Yojson.Safe.to_string pr1_baseline_no_id
            <> Yojson.Safe.to_string pr2_with_id_null in
  if not differ then
    Alcotest.fail
      "PR-2 should differ from PR-1 baseline by adding id:null; if this \
       fails, the wire change was reverted unintentionally"

let () =
  Alcotest.run "Error_body_delegation"
    [
      ( "error_body wire shape",
        [
          test_case "id:null by default" `Quick
            test_error_body_includes_id_null_by_default;
          test_case "id echoes when supplied" `Quick
            test_error_body_echoes_request_id;
          test_case "data field when supplied" `Quick
            test_error_body_includes_data_when_supplied;
        ] );
      ( "legacy delegation",
        [
          test_case "mcp_internal_error_json delegates" `Quick
            test_mcp_internal_error_json_now_typed;
          test_case "mcp_internal_error_json ~id delegates" `Quick
            test_mcp_internal_error_json_with_id;
          test_case "PR-2 wire-byte change is intentional" `Quick
            test_wire_byte_change_documented;
        ] );
    ]
