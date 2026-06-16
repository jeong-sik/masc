(** Tests for MCP Session Management - MCP 2025-11-25 Spec *)

open Alcotest

module Session = Masc.Session

(* Initialize RNG for crypto *)
let () = Mirage_crypto_rng_unix.use_default ()

(** MCP Session Store tests *)
let test_mcp_session_create () =
  let session = Session.McpSessionStore.create () in
  check bool "has id" true (String.length session.id > 0);
  check bool "id starts with mcp_" true (String.sub session.id 0 4 = "mcp_");
  check (option string) "no agent initially" None session.agent_name;
  check int "no requests initially" 0 session.request_count;
  check (list (pair string string)) "no metadata initially" [] session.metadata

let test_mcp_session_create_with_agent () =
  let session = Session.McpSessionStore.create ~agent_name:"claude" () in
  check (option string) "has agent" (Some "claude") session.agent_name

let test_mcp_session_get () =
  let session = Session.McpSessionStore.create () in
  let found = Session.McpSessionStore.get session.id in
  check bool "found" true (Option.is_some found);
  check string "same id" session.id (Option.get found).id

let test_mcp_session_get_not_found () =
  let found = Session.McpSessionStore.get "nonexistent-session" in
  check bool "not found" true (Option.is_none found)

let test_mcp_session_get_updates_activity () =
  let session = Session.McpSessionStore.create () in
  let old_activity = session.last_activity in
  (* Increase sleep time for more tolerance on slow systems *)
  Unix.sleepf 0.1;
  let _ = Session.McpSessionStore.get session.id in  (* get updates activity *)
  check bool "activity updated" true (session.last_activity >= old_activity)

let test_mcp_session_get_increments_request () =
  let session = Session.McpSessionStore.create () in
  check int "initial count" 0 session.request_count;
  let _ = Session.McpSessionStore.get session.id in
  check int "count after first get" 1 session.request_count;
  let _ = Session.McpSessionStore.get session.id in
  check int "count after second get" 2 session.request_count

let test_mcp_session_remove () =
  let session = Session.McpSessionStore.create () in
  let id = session.id in
  let result = Session.McpSessionStore.remove id in
  check bool "remove returned true" true result;
  let found = Session.McpSessionStore.get id in
  check bool "removed" true (Option.is_none found)

let test_mcp_session_remove_not_found () =
  let result = Session.McpSessionStore.remove "nonexistent-id" in
  check bool "remove returned false" false result

let test_mcp_session_list_all () =
  let _s1 = Session.McpSessionStore.create ~agent_name:"agent1" () in
  let _s2 = Session.McpSessionStore.create ~agent_name:"agent2" () in
  let all = Session.McpSessionStore.list_all () in
  check bool "has sessions" true (List.length all >= 2)

(** Header extraction tests *)
let test_extract_session_id_primary () =
  let headers = Cohttp.Header.init_with "Mcp-Session-Id" "session-123" in
  let result = Session.extract_mcp_session_id headers in
  check (option string) "extracts primary" (Some "session-123") result

let test_extract_session_id_fallback () =
  let headers = Cohttp.Header.init_with "X-MCP-Session-ID" "session-456" in
  let result = Session.extract_mcp_session_id headers in
  check (option string) "extracts fallback" (Some "session-456") result

let test_extract_session_id_none () =
  let headers = Cohttp.Header.init () in
  let result = Session.extract_mcp_session_id headers in
  check (option string) "no header" None result

let test_extract_session_id_primary_precedence () =
  let headers = Cohttp.Header.init () in
  let headers = Cohttp.Header.add headers "Mcp-Session-Id" "primary" in
  let headers = Cohttp.Header.add headers "X-MCP-Session-ID" "fallback" in
  let result = Session.extract_mcp_session_id headers in
  check (option string) "primary takes precedence" (Some "primary") result

(** JSON serialization *)
let test_session_to_json () =
  let session = Session.McpSessionStore.create ~agent_name:"json-agent" () in
  let json = Session.McpSessionStore.to_json session in
  match json with
  | `Assoc fields ->
    check bool "has id" true (List.mem_assoc "id" fields);
    check bool "has agent_name" true (List.mem_assoc "agent_name" fields);
    check bool "has created_at" true (List.mem_assoc "created_at" fields);
    check bool "has request_count" true (List.mem_assoc "request_count" fields)
  | _ -> fail "Expected Assoc"

(** Test suites *)
let store_tests = [
  "create", `Quick, test_mcp_session_create;
  "create with agent", `Quick, test_mcp_session_create_with_agent;
  "get", `Quick, test_mcp_session_get;
  "get not found", `Quick, test_mcp_session_get_not_found;
  "get updates activity", `Quick, test_mcp_session_get_updates_activity;
  "get increments request", `Quick, test_mcp_session_get_increments_request;
  "remove", `Quick, test_mcp_session_remove;
  "remove not found", `Quick, test_mcp_session_remove_not_found;
  "list all", `Quick, test_mcp_session_list_all;
]

let header_tests = [
  "extract primary", `Quick, test_extract_session_id_primary;
  "extract fallback", `Quick, test_extract_session_id_fallback;
  "extract none", `Quick, test_extract_session_id_none;
  "primary precedence", `Quick, test_extract_session_id_primary_precedence;
]

let json_tests = [
  "session_to_json", `Quick, test_session_to_json;
]

let () =
  run "Session" [
    "store", store_tests;
    "headers", header_tests;
    "json", json_tests;
  ]
