(** Transport Module Coverage Tests

    - protocol: protocol_to_string
    - Rest: method_to_string, generate_openapi_document
*)

open Alcotest

module Transport = Masc.Transport

(* ============================================================
   protocol Tests
   ============================================================ *)

let test_protocol_jsonrpc () =
  let p = Transport.JsonRpc in
  check string "jsonrpc string" "json-rpc" (Transport.protocol_to_string p)

let test_protocol_rest () =
  let p = Transport.Rest in
  check string "rest string" "rest" (Transport.protocol_to_string p)

let test_protocol_grpc () =
  let p = Transport.Grpc in
  check string "grpc string" "grpc" (Transport.protocol_to_string p)

let test_protocol_sse () =
  let p = Transport.Sse in
  check string "sse string" "sse" (Transport.protocol_to_string p)

let test_protocol_ws () =
  let p = Transport.Ws in
  check string "ws string" "ws" (Transport.protocol_to_string p)

(* ============================================================
   Rest Module Tests
   ============================================================ *)

let test_rest_method_to_string_get () =
  check string "GET" "GET" (Transport.Rest.method_to_string Transport.Rest.GET)

let test_rest_method_to_string_post () =
  check string "POST" "POST" (Transport.Rest.method_to_string Transport.Rest.POST)

let test_rest_generate_openapi_document () =
  let open Yojson.Safe.Util in
  let doc = Transport.Rest.generate_openapi_document ~scheme:"http" () in
  check string "openapi version" "3.1.0" (doc |> member "openapi" |> to_string);
  check string "info.version matches repo version" Runtime_build_version.current
    (doc |> member "info" |> member "version" |> to_string);
  check string "bearer security scheme type" "http"
    (doc |> member "components" |> member "securitySchemes"
     |> member "bearerAuth" |> member "type" |> to_string);
  check string "bearer security scheme" "bearer"
    (doc |> member "components" |> member "securitySchemes"
     |> member "bearerAuth" |> member "scheme" |> to_string);
  let mcp_post = doc |> member "paths" |> member "/mcp" |> member "post" in
  check string "mcp operation id" "mcp_tools_call"
    (mcp_post |> member "operationId" |> to_string);
  check string "mcp auth mode" "conditional_bearer"
    (mcp_post |> member "x-auth-mode" |> to_string);
  check bool "mcp security present" true
    (mcp_post |> member "security" <> `Null);
  let operations = mcp_post |> member "x-mcp-operations" |> to_list in
  let operation_entry operation_id =
    operations
    |> List.find (fun row ->
           row |> member "operationId" |> to_string = operation_id)
  in
  let check_operation_tags operation_id expected =
    let tags =
      operation_entry operation_id |> member "tags" |> to_list
      |> List.map to_string
    in
    check (list string) (operation_id ^ " tags") expected tags
  in
  let status_entry = operation_entry "masc_status" in
  check bool "status summary non-empty" true
    (String.length (status_entry |> member "summary" |> to_string) > 0);
  check_operation_tags "masc_status" [ "tasks" ];
  check_operation_tags "masc_broadcast" [ "messaging" ];
  let agent_core_aliases =
    status_entry |> member "x-agent-core" |> member "aliases" |> to_list
  in
  check bool "status has no sdk alias masc_workspace_status" false
    (List.exists
       (fun row -> row |> member "name" |> to_string = "masc_workspace_status")
       agent_core_aliases);
  let add_task_entry = operation_entry "masc_add_task" in
  check int "add_task has no fake rest binding"
    0
    (add_task_entry |> member "x-rest-bindings" |> to_list |> List.length);
  let broadcast_entry = operation_entry "masc_broadcast" in
  check bool "broadcast rest binding is real" true
    (List.exists
       (fun row ->
         row |> member "path" |> to_string = "/api/v1/broadcast")
       (broadcast_entry |> member "x-rest-bindings" |> to_list));
  let broadcast_post =
    doc |> member "paths" |> member "/api/v1/broadcast" |> member "post"
  in
  check (list string) "broadcast REST operation tags" [ "messaging" ]
    (broadcast_post |> member "tags" |> to_list |> List.map to_string);
  check string "broadcast auth mode" "bearer_required"
    (broadcast_post |> member "x-auth-mode" |> to_string);
  check bool "broadcast security present" true
    (broadcast_post |> member "security" <> `Null);
  check bool "broadcast 401 documented" true
    (broadcast_post |> member "responses" |> member "401" <> `Null);
  check bool "broadcast 403 documented" true
    (broadcast_post |> member "responses" |> member "403" <> `Null)

let test_rest_generate_openapi_document_relative_server_fallback () =
  let open Yojson.Safe.Util in
  let doc = Transport.Rest.generate_openapi_document ~scheme:"http" ~host:"" ~port:0 () in
  check string "relative server url when host unknown" "/"
    (doc |> member "servers" |> index 0 |> member "url" |> to_string)

(* [host] defaults to MASC_HOST, the bind setting, and the HTTP callers pass a
   Host header -- either can name every interface instead of a peer. "servers"
   is what a reader dials, so it gets folded (#30383). *)
let test_rest_generate_openapi_document_folds_a_wildcard_host () =
  let open Yojson.Safe.Util in
  let doc =
    Transport.Rest.generate_openapi_document ~scheme:"http" ~host:"0.0.0.0" ~port:8935 ()
  in
  check string "a bind wildcard is not advertised as a server address"
    "http://127.0.0.1:8935"
    (doc |> member "servers" |> index 0 |> member "url" |> to_string)

(* The TLS listener admits a port-less Host at the https default port, and
   the document it serves sends its reader back over https (#50025). *)
let test_rest_generate_openapi_document_keeps_the_https_scheme () =
  let open Yojson.Safe.Util in
  let doc =
    Transport.Rest.generate_openapi_document ~scheme:"https" ~host:"127.0.0.1" ~port:443 ()
  in
  check string "the servers url is dialled over https" "https://127.0.0.1:443"
    (doc |> member "servers" |> index 0 |> member "url" |> to_string)

(* An IPv6 host keeps its brackets in the servers url: without them the port
   reads as one more group of the address (#50058). *)
let test_rest_generate_openapi_document_brackets_an_ipv6_host () =
  let open Yojson.Safe.Util in
  let doc =
    Transport.Rest.generate_openapi_document ~scheme:"https" ~host:"fd00::1" ~port:8443 ()
  in
  check string "the servers url of an IPv6 host" "https://[fd00::1]:8443"
    (doc |> member "servers" |> index 0 |> member "url" |> to_string)

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Transport Coverage" [
    "protocol.to_string", [
      test_case "jsonrpc" `Quick test_protocol_jsonrpc;
      test_case "rest" `Quick test_protocol_rest;
      test_case "grpc" `Quick test_protocol_grpc;
      test_case "sse" `Quick test_protocol_sse;
      test_case "ws" `Quick test_protocol_ws;
    ];
    "rest.method_to_string", [
      test_case "GET" `Quick test_rest_method_to_string_get;
      test_case "POST" `Quick test_rest_method_to_string_post;
    ];
    "rest.generate_openapi_document", [
      test_case "document" `Quick test_rest_generate_openapi_document;
      test_case "relative server fallback" `Quick
        test_rest_generate_openapi_document_relative_server_fallback;
      test_case "openapi document folds a wildcard host" `Quick
        test_rest_generate_openapi_document_folds_a_wildcard_host;
      test_case "openapi document keeps the https scheme" `Quick
        test_rest_generate_openapi_document_keeps_the_https_scheme;
      test_case "openapi document brackets an IPv6 host" `Quick
        test_rest_generate_openapi_document_brackets_an_ipv6_host;
    ];
  ]
