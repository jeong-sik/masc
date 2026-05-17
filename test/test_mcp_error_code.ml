(** Uniqueness + range tests for [Mcp_error_code.t] (RFC-0098).

    These tests pin the closed-variant contract: every constructor maps
    to a unique wire integer, every wire integer lies in the
    JSON-RPC 2.0 reserved range, and the round-trip survives
    [to_wire_code]/[of_wire_code]. Drift here will break MCP clients
    that switch on the integer code. *)

open Alcotest
module C = Masc_mcp.Mcp_error_code

(* JSON-RPC 2.0 §5.1: implementation-defined codes live in
   [-32000, -32099]; the well-known set occupies -32700, -32600..-32603. *)
let in_jsonrpc_range code =
  let well_known = [ -32700; -32600; -32601; -32602; -32603 ] in
  List.mem code well_known || (code >= -32099 && code <= -32000)

let test_wire_codes_unique () =
  let codes = List.map C.to_wire_code C.all in
  let unique = List.sort_uniq compare codes in
  if List.length codes <> List.length unique then
    Alcotest.failf "wire codes are not unique: %s"
      (String.concat ", " (List.map string_of_int codes))

let test_wire_codes_in_range () =
  List.iter
    (fun t ->
      let code = C.to_wire_code t in
      if not (in_jsonrpc_range code) then
        Alcotest.failf "%a maps to %d which is outside JSON-RPC 2.0 reserved range"
          C.pp t code)
    C.all

let test_round_trip_well_known () =
  (* [of_wire_code] returns [None] for [Quiet] because the
     reason/recovered payload is not derivable from the integer alone.
     Skip [Quiet _] in this round-trip — the contract is documented in
     the .mli. *)
  List.iter
    (fun t ->
      match t with
      | C.Quiet _ -> ()
      | _ ->
          let code = C.to_wire_code t in
          match C.of_wire_code code with
          | Some t' when t' = t -> ()
          | Some t' ->
              Alcotest.failf "round-trip drift: %a -> %d -> %a" C.pp t code C.pp
                t'
          | None ->
              Alcotest.failf "of_wire_code returned None for known code %d"
                code)
    C.all

let test_of_wire_unknown_returns_none () =
  (* Unknown integer codes must return [None] rather than collapsing to
     [Internal_error]. Callers rely on this to detect contract drift —
     the same rationale as [Auth_error_kind.of_string]. *)
  let unknowns = [ 0; -1; -32100; -31999; -32500; 200 ] in
  List.iter
    (fun code ->
      match C.of_wire_code code with
      | None -> ()
      | Some t ->
          Alcotest.failf "of_wire_code should return None for %d, got %a" code
            C.pp t)
    unknowns

let test_quiet_round_trip_loses_payload () =
  (* Documentation contract: [Quiet] maps to -32099 but [of_wire_code
     (-32099)] returns [None] because the payload is not encoded in
     the integer. *)
  let q = C.Quiet { reason = "test skip"; recovered = true } in
  let code = C.to_wire_code q in
  Alcotest.(check int) "quiet maps to -32099" (-32099) code ;
  Alcotest.(check (option pass))
    "of_wire_code (-32099) returns None"
    None
    (C.of_wire_code (-32099))

let test_default_messages_non_empty () =
  List.iter
    (fun t ->
      let msg = C.to_wire_message_default t in
      if String.length msg = 0 then
        Alcotest.failf "%a has empty default message" C.pp t)
    C.all

let test_http_status_quiet_is_ok () =
  (* By contract: [Quiet _] is not a failure response. Embedded in a
     200 the client sees the [Quiet] envelope as a declared skip
     without HTTP error-handling kicking in. *)
  let q = C.Quiet { reason = "intentional"; recovered = false } in
  match C.to_http_status q with
  | `OK -> ()
  | _ -> Alcotest.fail "Quiet must map to HTTP 200 OK"

let () =
  Alcotest.run "Mcp_error_code"
    [
      ( "wire-codes",
        [
          test_case "unique" `Quick test_wire_codes_unique;
          test_case "in-range" `Quick test_wire_codes_in_range;
          test_case "round-trip (well-known)" `Quick test_round_trip_well_known;
          test_case "unknown returns None" `Quick
            test_of_wire_unknown_returns_none;
          test_case "Quiet round-trip drops payload" `Quick
            test_quiet_round_trip_loses_payload;
        ] );
      ( "messages-and-status",
        [
          test_case "default messages non-empty" `Quick
            test_default_messages_non_empty;
          test_case "Quiet -> 200 OK" `Quick test_http_status_quiet_is_ok;
        ] );
    ]
