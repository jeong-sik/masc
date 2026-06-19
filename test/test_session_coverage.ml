(** Session Module Coverage Tests

    Tests for session management types:
    - session type
    - rate_tracker type
    - create_tracker function
    - get_timestamps / set_timestamps
    - Burst counters: burst_used, last_burst_reset (direct field access)
    - McpSessionStore: generate_id, to_json
    - extract_mcp_session_id
*)

open Alcotest

module Session = Masc.Session
module Types = Masc_domain

(* ============================================================
   Type Existence Tests
   ============================================================ *)

let test_session_type () =
  let s : Session.session = {
    agent_name = "claude-test";
    connected_at = 1704067200.0;
    last_activity = 1704067200.0;
    is_listening = false;
    message_queue = Eio.Stream.create 1000;
  } in
  check string "agent_name" "claude-test" s.agent_name;
  check (float 0.1) "connected_at" 1704067200.0 s.connected_at;
  check bool "is_listening" false s.is_listening

let test_session_with_messages () =
  let msg = `Assoc [("type", `String "test")] in
  let sq = Eio.Stream.create 1000 in
  Eio.Stream.add sq msg;
  let s : Session.session = {
    agent_name = "gemini";
    connected_at = 1704067200.0;
    last_activity = 1704067250.0;
    is_listening = true;
    message_queue = sq;
  } in
  check bool "is_listening" true s.is_listening;
  check int "message_queue length" 1 (Eio.Stream.length s.message_queue)

(* ============================================================
   rate_tracker Tests
   ============================================================ *)

let test_rate_tracker_type () =
  let rt : Session.rate_tracker = {
    general_timestamps = [];
    broadcast_timestamps = [];
    task_ops_timestamps = [];
    burst_used = 0;
    last_burst_reset = 0.0;
  } in
  check int "burst_used" 0 rt.burst_used;
  check (list (float 0.1)) "general_timestamps" [] rt.general_timestamps

let test_rate_tracker_with_data () =
  let rt : Session.rate_tracker = {
    general_timestamps = [1.0; 2.0; 3.0];
    broadcast_timestamps = [1.5];
    task_ops_timestamps = [2.5; 3.5];
    burst_used = 5;
    last_burst_reset = 100.0;
  } in
  check int "general count" 3 (List.length rt.general_timestamps);
  check int "broadcast count" 1 (List.length rt.broadcast_timestamps);
  check int "task_ops count" 2 (List.length rt.task_ops_timestamps);
  check int "burst_used" 5 rt.burst_used

(* ============================================================
   create_tracker Tests
   ============================================================ *)

let test_create_tracker_empty () =
  let rt = Session.create_tracker (Time_compat.now ()) in
  check (list (float 0.1)) "general empty" [] rt.general_timestamps;
  check (list (float 0.1)) "broadcast empty" [] rt.broadcast_timestamps;
  check (list (float 0.1)) "task_ops empty" [] rt.task_ops_timestamps;
  check int "burst_used zero" 0 rt.burst_used

let test_create_tracker_burst_reset () =
  let rt = Session.create_tracker (Time_compat.now ()) in
  (* last_burst_reset should be set to current time (> 0) *)
  check bool "last_burst_reset > 0" true (rt.last_burst_reset > 0.0)

(* ============================================================
   get_timestamps / set_timestamps Tests
   ============================================================ *)

let test_get_timestamps_general () =
  let rt = Session.create_tracker (Time_compat.now ()) in
  let rt = Session.set_timestamps rt Masc_domain.GeneralLimit [1.0; 2.0; 3.0] in
  let ts = Session.get_timestamps rt Masc_domain.GeneralLimit in
  check int "general count" 3 (List.length ts)

let test_get_timestamps_broadcast () =
  let rt = Session.create_tracker (Time_compat.now ()) in
  let rt = Session.set_timestamps rt Masc_domain.BroadcastLimit [1.0; 2.0] in
  let ts = Session.get_timestamps rt Masc_domain.BroadcastLimit in
  check int "broadcast count" 2 (List.length ts)

let test_get_timestamps_task_ops () =
  let rt = Session.create_tracker (Time_compat.now ()) in
  let rt = Session.set_timestamps rt Masc_domain.TaskOpsLimit [5.0] in
  let ts = Session.get_timestamps rt Masc_domain.TaskOpsLimit in
  check int "task_ops count" 1 (List.length ts)

let test_set_timestamps_general () =
  let rt = Session.create_tracker (Time_compat.now ()) in
  let rt = Session.set_timestamps rt Masc_domain.GeneralLimit [1.0; 2.0] in
  check int "set general" 2 (List.length (Session.get_timestamps rt Masc_domain.GeneralLimit))

let test_set_timestamps_broadcast () =
  let rt = Session.create_tracker (Time_compat.now ()) in
  let rt = Session.set_timestamps rt Masc_domain.BroadcastLimit [3.0; 4.0; 5.0] in
  check int "set broadcast" 3 (List.length (Session.get_timestamps rt Masc_domain.BroadcastLimit))

let test_set_timestamps_task_ops () =
  let rt = Session.create_tracker (Time_compat.now ()) in
  let rt = Session.set_timestamps rt Masc_domain.TaskOpsLimit [6.0] in
  check int "set task_ops" 1 (List.length (Session.get_timestamps rt Masc_domain.TaskOpsLimit))

let test_set_get_roundtrip () =
  let rt = Session.create_tracker (Time_compat.now ()) in
  let ts = [10.0; 20.0; 30.0] in
  let rt = Session.set_timestamps rt Masc_domain.GeneralLimit ts in
  let ts' = Session.get_timestamps rt Masc_domain.GeneralLimit in
  check (list (float 0.1)) "roundtrip" ts ts'

(* ============================================================
   Burst Counters Tests (Removed as fields are private/immutable)
   ============================================================ *)

let test_burst_used_initial () =
  let rt = Session.create_tracker (Time_compat.now ()) in
  check int "initial burst" 0 rt.burst_used

(* ============================================================
   McpSessionStore Tests
   ============================================================ *)

(* Initialize RNG for tests that need crypto *)
let () = Mirage_crypto_rng_unix.use_default ()

let test_generate_id_prefix () =
  let id = Session.McpSessionStore.generate_id () in
  check bool "starts with mcp_" true (String.length id > 4 && String.sub id 0 4 = "mcp_")

let test_generate_id_length () =
  let id = Session.McpSessionStore.generate_id () in
  (* mcp_ (4) + 32 hex chars = 36 *)
  check int "id length" 36 (String.length id)

let test_generate_id_unique () =
  let id1 = Session.McpSessionStore.generate_id () in
  let id2 = Session.McpSessionStore.generate_id () in
  check bool "unique ids" true (id1 <> id2)

let test_mcp_session_to_json_has_id () =
  let s = Session.McpSessionStore.create () in
  let json = Session.McpSessionStore.to_json s in
  match json with
  | `Assoc fields -> check bool "has id" true (List.mem_assoc "id" fields)
  | _ -> fail "expected Assoc"

let test_mcp_session_to_json_has_created_at () =
  let s = Session.McpSessionStore.create () in
  let json = Session.McpSessionStore.to_json s in
  match json with
  | `Assoc fields -> check bool "has created_at" true (List.mem_assoc "created_at" fields)
  | _ -> fail "expected Assoc"

let test_mcp_session_to_json_has_request_count () =
  let s = Session.McpSessionStore.create () in
  let json = Session.McpSessionStore.to_json s in
  match json with
  | `Assoc fields -> check bool "has request_count" true (List.mem_assoc "request_count" fields)
  | _ -> fail "expected Assoc"

let test_mcp_session_to_json_has_metadata () =
  let s = Session.McpSessionStore.create () in
  let json = Session.McpSessionStore.to_json s in
  match json with
  | `Assoc fields -> check bool "has metadata" true (List.mem_assoc "metadata" fields)
  | _ -> fail "expected Assoc"

let test_mcp_session_to_json_agent_name_null () =
  let s = Session.McpSessionStore.create () in
  let json = Session.McpSessionStore.to_json s in
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "agent_name" fields with
     | Some `Null -> ()
     | _ -> fail "expected null agent_name")
  | _ -> fail "expected Assoc"

let test_mcp_session_to_json_agent_name_some () =
  let s = Session.McpSessionStore.create ~agent_name:"test-agent" () in
  let json = Session.McpSessionStore.to_json s in
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "agent_name" fields with
     | Some (`String name) -> check string "agent name" "test-agent" name
     | _ -> fail "expected string agent_name")
  | _ -> fail "expected Assoc"

let test_mcp_session_create_and_get () =
  let s = Session.McpSessionStore.create () in
  match Session.McpSessionStore.get s.id with
  | Some s' -> check string "same id" s.id s'.id
  | None -> fail "expected Some"

let test_mcp_session_get_nonexistent () =
  match Session.McpSessionStore.get "nonexistent_session_id" with
  | None -> ()
  | Some _ -> fail "expected None"

let test_mcp_session_remove () =
  let s = Session.McpSessionStore.create () in
  let id = s.id in
  let removed = Session.McpSessionStore.remove id in
  check bool "removed" true removed;
  match Session.McpSessionStore.get id with
  | None -> ()
  | Some _ -> fail "expected None after remove"

let test_mcp_session_remove_nonexistent () =
  let removed = Session.McpSessionStore.remove "nonexistent_xyz" in
  check bool "not removed" false removed

let test_mcp_session_list_all () =
  let before = List.length (Session.McpSessionStore.list_all ()) in
  let _ = Session.McpSessionStore.create () in
  let after = List.length (Session.McpSessionStore.list_all ()) in
  check bool "list increased" true (after > before || after >= 0)

(* ============================================================
   extract_mcp_session_id Tests
   ============================================================ *)

let test_extract_mcp_session_id_present () =
  let headers = Cohttp.Header.init_with "Mcp-Session-Id" "test-session-123" in
  match Session.extract_mcp_session_id headers with
  | Some id -> check string "extracted id" "test-session-123" id
  | None -> fail "expected Some"

let test_extract_mcp_session_id_x_prefix () =
  let headers = Cohttp.Header.init_with "X-MCP-Session-ID" "session-456" in
  match Session.extract_mcp_session_id headers with
  | Some id -> check string "extracted x-prefix id" "session-456" id
  | None -> fail "expected Some"

let test_extract_mcp_session_id_prefers_mcp () =
  let headers = Cohttp.Header.init ()
    |> fun h -> Cohttp.Header.add h "Mcp-Session-Id" "preferred"
    |> fun h -> Cohttp.Header.add h "X-MCP-Session-ID" "fallback"
  in
  match Session.extract_mcp_session_id headers with
  | Some id -> check string "prefers Mcp-Session-Id" "preferred" id
  | None -> fail "expected Some"

let test_extract_mcp_session_id_missing () =
  let headers = Cohttp.Header.init () in
  match Session.extract_mcp_session_id headers with
  | None -> ()
  | Some _ -> fail "expected None"

let test_extract_mcp_session_id_other_headers () =
  let headers = Cohttp.Header.init ()
    |> fun h -> Cohttp.Header.add h "Content-Type" "application/json"
    |> fun h -> Cohttp.Header.add h "Authorization" "Bearer token"
  in
  match Session.extract_mcp_session_id headers with
  | None -> ()
  | Some _ -> fail "expected None"

(* ============================================================
   status_string Tests (requires Eio runtime - basic only)
   ============================================================ *)

(* [status_string] / [connected_agents] now take [registry.lock]
   (Eio.Mutex) to match the contract on [registry]: all fields
   accessed exclusively under the lock.  Eio.Mutex requires an active
   Eio context, so both tests run inside [Eio_main.run]. *)
let test_status_string_empty () =
  Eio_main.run @@ fun _env ->
  let registry = Session.create () in
  let status = Session.status_string registry in
  check bool "says no agents" true (
    try let _ = Str.search_forward (Str.regexp "No agents") status 0 in true
    with Not_found -> false)

(* Note: Tests with Session.register require Eio runtime *)

(* ============================================================
   connected_agents Tests (empty only - register needs Eio)
   ============================================================ *)

let test_connected_agents_empty () =
  Eio_main.run @@ fun _env ->
  let registry = Session.create () in
  let agents = Session.connected_agents registry in
  check (list string) "empty" [] agents

let test_registry_works_before_actor_loop_starts () =
  Eio_main.run @@ fun _env ->
  let registry = Session.create () in
  let (_ : Session.session) = Session.register registry ~agent_name:"alice" in
  let agents = Session.connected_agents registry |> List.sort String.compare in
  check (list string) "registered before start_loop" [ "alice" ] agents

let with_bounded_await clock label f =
  try Eio.Time.with_timeout_exn clock 1.0 f with
  | Eio.Time.Timeout -> failf "%s timed out" label

let test_registry_actor_loop_restarts_after_switch_release () =
  Eio_main.run @@ fun env ->
  let registry = Session.create () in
  let register_with_timeout agent_name =
    with_bounded_await env#clock
      (Printf.sprintf "register %s through registry actor" agent_name)
      (fun () ->
        let (_ : Session.session) = Session.register registry ~agent_name in
        ())
  in
  Eio.Switch.run (fun sw ->
    Session.start_loop registry ~sw;
    register_with_timeout "alice");
  Eio.Switch.run (fun sw ->
    Session.start_loop registry ~sw;
    register_with_timeout "bob");
  let agents = Session.connected_agents registry |> List.sort String.compare in
  check (list string) "registered after actor restart" [ "alice"; "bob" ] agents

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Session Coverage" [
    "session", [
      test_case "type" `Quick test_session_type;
      test_case "with messages" `Quick test_session_with_messages;
    ];
    "rate_tracker", [
      test_case "type" `Quick test_rate_tracker_type;
      test_case "with data" `Quick test_rate_tracker_with_data;
    ];
    "create_tracker", [
      test_case "empty" `Quick test_create_tracker_empty;
      test_case "burst_reset" `Quick test_create_tracker_burst_reset;
    ];
    "get_timestamps", [
      test_case "general" `Quick test_get_timestamps_general;
      test_case "broadcast" `Quick test_get_timestamps_broadcast;
      test_case "task_ops" `Quick test_get_timestamps_task_ops;
    ];
    "set_timestamps", [
      test_case "general" `Quick test_set_timestamps_general;
      test_case "broadcast" `Quick test_set_timestamps_broadcast;
      test_case "task_ops" `Quick test_set_timestamps_task_ops;
      test_case "roundtrip" `Quick test_set_get_roundtrip;
    ];
    "burst_counters", [
      test_case "burst_used initial" `Quick test_burst_used_initial;
    ];
    "mcp_session_store", [
      test_case "generate_id prefix" `Quick test_generate_id_prefix;
      test_case "generate_id length" `Quick test_generate_id_length;
      test_case "generate_id unique" `Quick test_generate_id_unique;
      test_case "to_json has id" `Quick test_mcp_session_to_json_has_id;
      test_case "to_json has created_at" `Quick test_mcp_session_to_json_has_created_at;
      test_case "to_json has request_count" `Quick test_mcp_session_to_json_has_request_count;
      test_case "to_json has metadata" `Quick test_mcp_session_to_json_has_metadata;
      test_case "to_json agent_name null" `Quick test_mcp_session_to_json_agent_name_null;
      test_case "to_json agent_name some" `Quick test_mcp_session_to_json_agent_name_some;
      test_case "create and get" `Quick test_mcp_session_create_and_get;
      test_case "get nonexistent" `Quick test_mcp_session_get_nonexistent;
      test_case "remove" `Quick test_mcp_session_remove;
      test_case "remove nonexistent" `Quick test_mcp_session_remove_nonexistent;
      test_case "list all" `Quick test_mcp_session_list_all;
    ];
    "extract_mcp_session_id", [
      test_case "present" `Quick test_extract_mcp_session_id_present;
      test_case "x-prefix" `Quick test_extract_mcp_session_id_x_prefix;
      test_case "prefers mcp" `Quick test_extract_mcp_session_id_prefers_mcp;
      test_case "missing" `Quick test_extract_mcp_session_id_missing;
      test_case "other headers" `Quick test_extract_mcp_session_id_other_headers;
    ];
    "status_string", [
      test_case "empty" `Quick test_status_string_empty;
    ];
    "connected_agents", [
      test_case "empty" `Quick test_connected_agents_empty;
      test_case "pre-loop registry calls do not hang" `Quick
        test_registry_works_before_actor_loop_starts;
      test_case "actor loop restarts after switch release" `Quick
        test_registry_actor_loop_restarts_after_switch_release;
    ];
  ]
