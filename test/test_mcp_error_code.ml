(** Uniqueness + range tests for [Mcp_error_code.t] (RFC-0098).

    These tests pin the closed-variant contract: every constructor maps
    to a unique wire integer, every wire integer lies in the
    JSON-RPC 2.0 reserved range, and the round-trip survives
    [to_wire_code]/[of_wire_code]. Drift here will break MCP clients
    that switch on the integer code. *)

open Alcotest
module C = Masc.Mcp_error_code

let string_contains haystack needle =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen > hlen then false
  else
    let found = ref false in
    for i = 0 to hlen - nlen do
      if not !found && String.sub haystack i nlen = needle then found := true
    done;
    !found

let index_of haystack needle =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen > hlen then None
  else (
    let found = ref None in
    for i = 0 to hlen - nlen do
      match !found with
      | Some _ -> ()
      | None ->
          if String.sub haystack i nlen = needle then found := Some i
    done;
    !found)

let index_of_after haystack needle start =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen > hlen || start > hlen - nlen then None
  else (
    let found = ref None in
    for i = start to hlen - nlen do
      match !found with
      | Some _ -> ()
      | None ->
          if String.sub haystack i nlen = needle then found := Some i
    done;
    !found)

let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      In_channel.input_all ic)

let rec find_source_root_from dir hops rel =
  if hops > 8 then None
  else if Sys.file_exists (Filename.concat dir rel) then Some dir
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir then None
    else find_source_root_from parent (hops + 1) rel

let source_root () =
  let anchor = "dune-project" in
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root
    when String.trim root <> "" && Sys.file_exists (Filename.concat root anchor) ->
      root
  | _ -> (
      match find_source_root_from (Sys.getcwd ()) 0 anchor with
      | Some root -> root
      | None -> fail "could not locate repo source root")

let read_source_file rel = read_file (Filename.concat (source_root ()) rel)

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

(* MCP revision 2026-07-28 pins this body, field for field: a client reading a
   4xx decides from it whether it is talking to a modern server or a legacy
   one. A missing [data.supported] does not degrade the error, it reclassifies
   the whole server, so each field is asserted rather than the string as a
   whole. *)
let test_unsupported_protocol_version_body_shape () =
  let body =
    C.unsupported_protocol_version_body ~requested:"1900-01-01"
      ~supported:[ "2026-07-28"; "2025-11-25" ]
  in
  let fields =
    match Yojson.Safe.from_string body with
    | `Assoc fields -> fields
    | _ -> Alcotest.fail "body is not a JSON object"
  in
  (match List.assoc_opt "jsonrpc" fields with
  | Some (`String v) -> Alcotest.(check string) "jsonrpc" "2.0" v
  | _ -> Alcotest.fail "jsonrpc version missing");
  (match List.assoc_opt "id" fields with
  | Some `Null -> ()
  | _ ->
      Alcotest.fail
        "id must be null: the header is rejected before the request id is read");
  let err =
    match List.assoc_opt "error" fields with
    | Some (`Assoc err) -> err
    | _ -> Alcotest.fail "error object missing"
  in
  (match List.assoc_opt "code" err with
  | Some (`Int code) ->
      Alcotest.(check int) "code fixed by the spec, not by this server" (-32022) code
  | _ -> Alcotest.fail "error.code missing");
  (match List.assoc_opt "message" err with
  | Some (`String m) ->
      Alcotest.(check string) "message" "Unsupported protocol version" m
  | _ -> Alcotest.fail "error.message missing");
  let data =
    match List.assoc_opt "data" err with
    | Some (`Assoc data) -> data
    | _ ->
        Alcotest.fail
          "error.data missing — without it the response is not a recognized \
           modern error and the client falls back to initialize"
  in
  (match List.assoc_opt "supported" data with
  | Some (`List vs) ->
      Alcotest.(check (list string))
        "supported list is what the client retries from"
        [ "2026-07-28"; "2025-11-25" ]
        (List.map
           (function
             | `String s -> s
             | _ -> Alcotest.fail "supported entry is not a string")
           vs)
  | _ -> Alcotest.fail "data.supported missing");
  match List.assoc_opt "requested" data with
  | Some (`String r) -> Alcotest.(check string) "requested echoed back" "1900-01-01" r
  | _ -> Alcotest.fail "data.requested missing"

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

let test_sse_register_error_body_uses_jsonrpc_invalid_request () =
  let open Yojson.Safe.Util in
  let body =
    C.jsonrpc_error_body C.Invalid_request ~message:"unknown session stale-mcp"
    |> Yojson.Safe.from_string
  in
  check string "jsonrpc" "2.0" (body |> member "jsonrpc" |> to_string);
  check string "id is null" "null" (body |> member "id" |> Yojson.Safe.to_string);
  let error = body |> member "error" in
  check int "invalid request code" (-32600) (error |> member "code" |> to_int);
  check string "message" "unknown session stale-mcp"
    (error |> member "message" |> to_string)

let test_sse_get_registers_before_streaming_response () =
  let http = read_source_file "lib/server/server_mcp_transport_http.ml" in
  let agui = read_source_file "lib/server/server_mcp_transport_http_agui.ml" in
  let assert_order label source =
    match index_of source "Sse.register" with
    | None -> fail (label ^ ": missing Sse.register")
    | Some register_at ->
        (match
           ( index_of_after source "respond_sse_register_error" register_at,
             index_of_after
               source
               "Httpun.Reqd.respond_with_streaming"
               register_at )
         with
         | Some error_at, Some stream_at ->
             check bool (label ^ " has register error before stream") true
               (register_at < error_at && error_at < stream_at)
         | _ ->
             fail (label ^ ": missing register error responder or streaming open"))
  in
  assert_order "generic SSE GET validates before 200 stream" http;
  assert_order "AG-UI SSE validates before 200 stream" agui

(* JSON-RPC 2.0 §5 allows a null id only when the id could not be read.
   Asserted over [C.all] rather than a hand-listed set, so a new code
   that quietly answers true is caught here as well as by the exhaustive
   match in the module. *)
let test_allows_null_request_id_only_for_unreadable_id () =
  let allowed = List.filter C.allows_null_request_id C.all in
  Alcotest.(check int) "exactly three codes allow a null id" 3 (List.length allowed);
  Alcotest.(check bool) "Parse_error" true (C.allows_null_request_id C.Parse_error);
  Alcotest.(check bool) "Invalid_request" true (C.allows_null_request_id C.Invalid_request);
  (* Third since the MCP 2026-07-28 version check: the declared version is
     read from the [MCP-Protocol-Version] header and rejected there, so the
     JSON-RPC body — and the id inside it — is never parsed. Same §5 condition
     as the other two, reached by a different route. A future rejection driven
     by the [_meta] key instead does parse the body, and would have to carry
     the id. *)
  Alcotest.(check bool) "Unsupported_protocol_version" true
    (C.allows_null_request_id C.Unsupported_protocol_version)
;;

let test_allows_null_request_id_rejects_answered_requests () =
  List.iter
    (fun code ->
      match code with
      | C.Parse_error | C.Invalid_request | C.Unsupported_protocol_version -> ()
      | other ->
        Alcotest.(check bool)
          (Printf.sprintf "%s must carry the request id" (Format.asprintf "%a" C.pp other))
          false
          (C.allows_null_request_id other))
    C.all
;;

let () =
  Alcotest.run "Mcp_error_code"
    [
      ( "wire-codes",
        [
          test_case "unique" `Quick test_wire_codes_unique;
          test_case "in-range" `Quick test_wire_codes_in_range;
          test_case "round-trip (well-known)" `Quick test_round_trip_well_known;
          test_case "unsupported protocol version body (MCP 2026-07-28)" `Quick
            test_unsupported_protocol_version_body_shape;
          test_case "unknown returns None" `Quick
            test_of_wire_unknown_returns_none;
          test_case "Quiet round-trip drops payload" `Quick
            test_quiet_round_trip_loses_payload;
        ] );
      ( "null-request-id",
        [
          test_case "only unreadable-id codes allow null" `Quick
            test_allows_null_request_id_only_for_unreadable_id;
          test_case "every answered request keeps its id" `Quick
            test_allows_null_request_id_rejects_answered_requests;
        ] );
      ( "messages-and-status",
        [
          test_case "default messages non-empty" `Quick
            test_default_messages_non_empty;
          test_case "Quiet -> 200 OK" `Quick test_http_status_quiet_is_ok;
          test_case "SSE register error JSON-RPC body" `Quick
            test_sse_register_error_body_uses_jsonrpc_invalid_request;
          test_case "SSE GET validates before opening stream" `Quick
            test_sse_get_registers_before_streaming_response;
        ] );
    ]
