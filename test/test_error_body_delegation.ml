(** Wire-shape assertions for [error_body] — the RFC-0098 SSOT.

    Originally written at PR-2 to assert *parity* between legacy
    [mcp_internal_error_json] and the new [error_body]. PR-4 removed
    the legacy function entirely; what remains is the standalone
    wire-shape contract for [error_body], plus a regression guard
    pinning the JSON-RPC 2.0 §5.1 [["id": null]] compliance fix
    introduced in PR-2.

    File name retained to keep git-blame continuity across PR-2 → PR-4. *)

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

let test_wire_byte_change_documented () =
  (* PR-2 wire-byte change regression guard — outlives the legacy
     factories removed in PR-4. Pre-PR-2 bodies omitted "id";
     [error_body] always emits "id":null per JSON-RPC 2.0 §5.1.
     A revert would break clients that switch on the typed shape. *)
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
      "PR-2 wire-byte change reverted unintentionally — error body \
       must include id:null per JSON-RPC 2.0 §5.1"

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
          test_case "PR-2 wire-byte change is intentional (regression guard)"
            `Quick test_wire_byte_change_documented;
        ] );
    ]
