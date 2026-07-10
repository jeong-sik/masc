(** Types Module Coverage Tests

    Tests for MASC Types - Domain Model:
    - Agent_id: of_string, to_string, equal, to_yojson, of_yojson
    - Task_id: of_string, to_string, equal, generate, to_yojson, of_yojson
    - now_iso, parse_iso8601
    - agent_status
*)

open Alcotest

module Types = Masc_domain

(* ============================================================
   Agent_id Tests
   ============================================================ *)

let test_agent_id_of_string () =
  let id = Masc_domain.Agent_id.of_string "claude-1" in
  let s = Masc_domain.Agent_id.to_string id in
  check string "roundtrip" "claude-1" s

let test_agent_id_equal_same () =
  let id1 = Masc_domain.Agent_id.of_string "agent-x" in
  let id2 = Masc_domain.Agent_id.of_string "agent-x" in
  check bool "equal" true (Masc_domain.Agent_id.equal id1 id2)

let test_agent_id_equal_diff () =
  let id1 = Masc_domain.Agent_id.of_string "agent-x" in
  let id2 = Masc_domain.Agent_id.of_string "agent-y" in
  check bool "not equal" false (Masc_domain.Agent_id.equal id1 id2)

let test_agent_id_to_yojson () =
  let id = Masc_domain.Agent_id.of_string "test-agent" in
  let json = Masc_domain.Agent_id.to_yojson id in
  match json with
  | `String s -> check string "to json" "test-agent" s
  | _ -> fail "expected String"

let test_agent_id_of_yojson_ok () =
  let json = `String "my-agent" in
  match Masc_domain.Agent_id.of_yojson json with
  | Ok id -> check string "from json" "my-agent" (Masc_domain.Agent_id.to_string id)
  | Error _ -> fail "expected Ok"

let test_agent_id_of_yojson_err () =
  let json = `Int 123 in
  match Masc_domain.Agent_id.of_yojson json with
  | Error _ -> ()
  | Ok _ -> fail "expected Error"

let test_agent_id_empty () =
  let id = Masc_domain.Agent_id.of_string "" in
  check string "empty" "" (Masc_domain.Agent_id.to_string id)

let test_agent_id_special_chars () =
  let id = Masc_domain.Agent_id.of_string "agent@domain:123" in
  check string "special chars" "agent@domain:123" (Masc_domain.Agent_id.to_string id)

(* ============================================================
   Task_id Tests
   ============================================================ *)

let test_task_id_of_string () =
  let id = Masc_domain.Task_id.of_string "task-001" in
  let s = Masc_domain.Task_id.to_string id in
  check string "roundtrip" "task-001" s

let test_task_id_equal_same () =
  let id1 = Masc_domain.Task_id.of_string "task-x" in
  let id2 = Masc_domain.Task_id.of_string "task-x" in
  check bool "equal" true (Masc_domain.Task_id.equal id1 id2)

let test_task_id_equal_diff () =
  let id1 = Masc_domain.Task_id.of_string "task-x" in
  let id2 = Masc_domain.Task_id.of_string "task-y" in
  check bool "not equal" false (Masc_domain.Task_id.equal id1 id2)

let test_task_id_generate () =
  let id = Masc_domain.Task_id.generate () in
  let s = Masc_domain.Task_id.to_string id in
  check bool "starts with task-" true (String.sub s 0 5 = "task-")

let test_task_id_generate_unique () =
  let id1 = Masc_domain.Task_id.generate () in
  let id2 = Masc_domain.Task_id.generate () in
  check bool "unique" false (Masc_domain.Task_id.equal id1 id2)

let test_task_id_to_yojson () =
  let id = Masc_domain.Task_id.of_string "task-123" in
  let json = Masc_domain.Task_id.to_yojson id in
  match json with
  | `String s -> check string "to json" "task-123" s
  | _ -> fail "expected String"

(* ============================================================
   Execution_id Tests (RFC-0233)
   ============================================================ *)

let test_execution_id_generate_prefix () =
  let s = Masc_domain.Execution_id.(to_string (generate ())) in
  check bool "starts with exec-" true (String.sub s 0 5 = "exec-")

let test_execution_id_generate_unique () =
  let id1 = Masc_domain.Execution_id.generate () in
  let id2 = Masc_domain.Execution_id.generate () in
  check bool "unique" false (Masc_domain.Execution_id.equal id1 id2)

let test_execution_id_mint_order_sorts () =
  (* Same-millisecond mints differ by sequence; the lexicographic order
     of the suffix tracks mint order within a process. *)
  let ids =
    List.init 50 (fun _ -> Masc_domain.Execution_id.(to_string (generate ())))
  in
  check (list string) "lexicographic order = mint order"
    ids (List.sort compare ids)

let test_execution_id_yojson_roundtrip () =
  let id = Masc_domain.Execution_id.of_string "exec-1718150400000-0001" in
  match Masc_domain.Execution_id.(of_yojson (to_yojson id)) with
  | Ok back ->
      check string "roundtrip" "exec-1718150400000-0001"
        (Masc_domain.Execution_id.to_string back)
  | Error _ -> fail "expected Ok"

let test_execution_id_of_yojson_rejects_non_string () =
  match Masc_domain.Execution_id.of_yojson (`Int 42) with
  | Ok _ -> fail "expected Error for non-string"
  | Error _ -> check bool "rejected" true true

let test_task_id_of_yojson_ok () =
  let json = `String "my-task" in
  match Masc_domain.Task_id.of_yojson json with
  | Ok id -> check string "from json" "my-task" (Masc_domain.Task_id.to_string id)
  | Error _ -> fail "expected Ok"

let test_task_id_of_yojson_err () =
  let json = `Bool true in
  match Masc_domain.Task_id.of_yojson json with
  | Error _ -> ()
  | Ok _ -> fail "expected Error"

(* ============================================================
   Timestamp Tests
   ============================================================ *)

let test_now_iso_format () =
  let ts = Masc_domain.now_iso () in
  (* Should be like 2024-01-15T12:30:45Z *)
  check bool "length" true (String.length ts = 20);
  check bool "ends with Z" true (String.get ts 19 = 'Z');
  check bool "has T" true (String.get ts 10 = 'T')

let test_parse_iso8601_valid () =
  let ts = "2024-01-15T12:30:45Z" in
  let parsed = Masc_domain.parse_iso8601 ts in
  check bool "is float" true (parsed > 0.0)

let test_parse_iso8601_invalid () =
  let ts = "not-a-date" in
  let default = 123.0 in
  let parsed = Masc_domain.parse_iso8601 ~default_time:default ts in
  check (float 0.001) "uses default" default parsed

let test_parse_iso8601_empty () =
  let ts = "" in
  let default = 999.0 in
  let parsed = Masc_domain.parse_iso8601 ~default_time:default ts in
  check (float 0.001) "uses default" default parsed

(* ============================================================
   Agent Status Tests
   ============================================================ *)

let test_show_agent_status_active () =
  let s = Masc_domain.show_agent_status Masc_domain.Active in
  check bool "active" true (String.length s > 0)

let test_show_agent_status_busy () =
  let s = Masc_domain.show_agent_status Masc_domain.Busy in
  check bool "busy" true (String.length s > 0)

let test_show_agent_status_listening () =
  let s = Masc_domain.show_agent_status Masc_domain.Listening in
  check bool "listening" true (String.length s > 0)

let test_show_agent_status_inactive () =
  let s = Masc_domain.show_agent_status Masc_domain.Inactive in
  check bool "inactive" true (String.length s > 0)

(* ============================================================
   agent_status_to_string Tests
   ============================================================ *)

let test_agent_status_to_string_active () =
  check string "active" "active" (Masc_domain.agent_status_to_string Masc_domain.Active)

let test_agent_status_to_string_busy () =
  check string "busy" "busy" (Masc_domain.agent_status_to_string Masc_domain.Busy)

let test_agent_status_to_string_listening () =
  check string "listening" "listening" (Masc_domain.agent_status_to_string Masc_domain.Listening)

let test_agent_status_to_string_inactive () =
  check string "inactive" "inactive" (Masc_domain.agent_status_to_string Masc_domain.Inactive)

(* ============================================================
   agent_status_of_string_opt Tests
   ============================================================ *)

let test_agent_status_of_string_opt_active () =
  match Masc_domain.agent_status_of_string_opt "active" with
  | Some s -> check bool "is Active" true (s = Masc_domain.Active)
  | None -> fail "expected Some"

let test_agent_status_of_string_opt_busy () =
  match Masc_domain.agent_status_of_string_opt "busy" with
  | Some s -> check bool "is Busy" true (s = Masc_domain.Busy)
  | None -> fail "expected Some"

let test_agent_status_of_string_opt_listening () =
  match Masc_domain.agent_status_of_string_opt "listening" with
  | Some s -> check bool "is Listening" true (s = Masc_domain.Listening)
  | None -> fail "expected Some"

let test_agent_status_of_string_opt_inactive () =
  match Masc_domain.agent_status_of_string_opt "inactive" with
  | Some s -> check bool "is Inactive" true (s = Masc_domain.Inactive)
  | None -> fail "expected Some"

let test_agent_status_of_string_opt_unknown () =
  match Masc_domain.agent_status_of_string_opt "unknown-status" with
  | None -> ()
  | Some _ -> fail "expected None"

(* ============================================================
   agent_status_to_yojson Tests
   ============================================================ *)

let test_agent_status_to_yojson_active () =
  match Masc_domain.agent_status_to_yojson Masc_domain.Active with
  | `String s -> check string "active json" "active" s
  | _ -> fail "expected String"

let test_agent_status_to_yojson_busy () =
  match Masc_domain.agent_status_to_yojson Masc_domain.Busy with
  | `String s -> check string "busy json" "busy" s
  | _ -> fail "expected String"

(* ============================================================
   agent_status_of_yojson Tests
   ============================================================ *)

let test_agent_status_of_yojson_active () =
  match Masc_domain.agent_status_of_yojson (`String "active") with
  | Ok s -> check bool "is Active" true (s = Masc_domain.Active)
  | Error e -> fail e

let test_agent_status_of_yojson_busy () =
  match Masc_domain.agent_status_of_yojson (`String "busy") with
  | Ok s -> check bool "is Busy" true (s = Masc_domain.Busy)
  | Error e -> fail e

let test_agent_status_of_yojson_unknown () =
  match Masc_domain.agent_status_of_yojson (`String "invalid") with
  | Error _ -> ()
  | Ok _ -> fail "expected Error"

let test_agent_status_of_yojson_wrong_type () =
  match Masc_domain.agent_status_of_yojson (`Int 123) with
  | Error _ -> ()
  | Ok _ -> fail "expected Error"

(* ============================================================
   task_status_to_string Tests
   ============================================================ *)

let test_task_status_to_string_todo () =
  check string "todo" "todo" (Masc_domain.task_status_to_string Masc_domain.Todo)

let test_task_status_to_string_claimed () =
  let status = Masc_domain.Claimed { assignee = "claude"; claimed_at = "2024-01-01" } in
  check string "claimed" "claimed" (Masc_domain.task_status_to_string status)

let test_task_status_to_string_in_progress () =
  let status = Masc_domain.InProgress { assignee = "claude"; started_at = "2024-01-01" } in
  check string "in_progress" "in_progress" (Masc_domain.task_status_to_string status)

let test_task_status_to_string_done () =
  let status = Masc_domain.Done { assignee = "claude"; completed_at = "2024-01-01"; notes = None } in
  check string "done" "done" (Masc_domain.task_status_to_string status)

let test_task_status_to_string_cancelled () =
  let status = Masc_domain.Cancelled { cancelled_by = "user"; cancelled_at = "2024-01-01"; reason = None } in
  check string "cancelled" "cancelled" (Masc_domain.task_status_to_string status)

(* ============================================================
   task_status_to_yojson Tests
   ============================================================ *)

let test_task_status_to_yojson_todo () =
  let json = Masc_domain.task_status_to_yojson Masc_domain.Todo in
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "status" fields with
     | Some (`String "todo") -> ()
     | _ -> fail "expected status=todo")
  | _ -> fail "expected Assoc"

let test_task_status_to_yojson_claimed () =
  let status = Masc_domain.Claimed { assignee = "claude"; claimed_at = "2024-01-01T00:00:00Z" } in
  let json = Masc_domain.task_status_to_yojson status in
  match json with
  | `Assoc fields ->
    check bool "has status" true (List.mem_assoc "status" fields);
    check bool "has assignee" true (List.mem_assoc "assignee" fields);
    check bool "has claimed_at" true (List.mem_assoc "claimed_at" fields)
  | _ -> fail "expected Assoc"

let test_task_status_to_yojson_in_progress () =
  let status = Masc_domain.InProgress { assignee = "gemini"; started_at = "2024-01-01T12:00:00Z" } in
  let json = Masc_domain.task_status_to_yojson status in
  match json with
  | `Assoc fields ->
    check bool "has started_at" true (List.mem_assoc "started_at" fields)
  | _ -> fail "expected Assoc"

let test_task_status_to_yojson_done_with_notes () =
  let status = Masc_domain.Done { assignee = "codex"; completed_at = "2024-01-01"; notes = Some "All tests pass" } in
  let json = Masc_domain.task_status_to_yojson status in
  match json with
  | `Assoc fields ->
    check bool "has completed_at" true (List.mem_assoc "completed_at" fields);
    check bool "has notes" true (List.mem_assoc "notes" fields)
  | _ -> fail "expected Assoc"

let test_task_status_to_yojson_done_no_notes () =
  let status = Masc_domain.Done { assignee = "codex"; completed_at = "2024-01-01"; notes = None } in
  let json = Masc_domain.task_status_to_yojson status in
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "notes" fields with
     | Some `Null -> ()
     | _ -> fail "expected notes=Null")
  | _ -> fail "expected Assoc"

let test_task_status_to_yojson_cancelled_with_reason () =
  let status = Masc_domain.Cancelled { cancelled_by = "user"; cancelled_at = "2024-01-01"; reason = Some "No longer needed" } in
  let json = Masc_domain.task_status_to_yojson status in
  match json with
  | `Assoc fields ->
    check bool "has cancelled_by" true (List.mem_assoc "cancelled_by" fields);
    check bool "has reason" true (List.mem_assoc "reason" fields)
  | _ -> fail "expected Assoc"

(* ============================================================
   task_status_of_yojson Tests
   ============================================================ *)

let test_task_status_of_yojson_todo () =
  let json = `Assoc [("status", `String "todo")] in
  match Masc_domain.task_status_of_yojson json with
  | Ok Masc_domain.Todo -> ()
  | Ok _ -> fail "expected Todo"
  | Error e -> fail e

let test_task_status_of_yojson_claimed () =
  let json = `Assoc [
    ("status", `String "claimed");
    ("assignee", `String "claude");
    ("claimed_at", `String "2024-01-01")
  ] in
  match Masc_domain.task_status_of_yojson json with
  | Ok (Masc_domain.Claimed { assignee; _ }) -> check string "assignee" "claude" assignee
  | Ok _ -> fail "expected Claimed"
  | Error e -> fail e

let test_task_status_of_yojson_in_progress () =
  let json = `Assoc [
    ("status", `String "in_progress");
    ("assignee", `String "gemini");
    ("started_at", `String "2024-01-01")
  ] in
  match Masc_domain.task_status_of_yojson json with
  | Ok (Masc_domain.InProgress { assignee; _ }) -> check string "assignee" "gemini" assignee
  | Ok _ -> fail "expected InProgress"
  | Error e -> fail e

let test_task_status_of_yojson_done () =
  let json = `Assoc [
    ("status", `String "done");
    ("assignee", `String "codex");
    ("completed_at", `String "2024-01-01");
    ("notes", `String "Done!")
  ] in
  match Masc_domain.task_status_of_yojson json with
  | Ok (Masc_domain.Done { notes; _ }) -> check bool "has notes" true (notes = Some "Done!")
  | Ok _ -> fail "expected Done"
  | Error e -> fail e

let test_task_status_of_yojson_cancelled () =
  let json = `Assoc [
    ("status", `String "cancelled");
    ("cancelled_by", `String "user");
    ("cancelled_at", `String "2024-01-01");
    ("reason", `Null)
  ] in
  match Masc_domain.task_status_of_yojson json with
  | Ok (Masc_domain.Cancelled { reason; _ }) -> check bool "no reason" true (reason = None)
  | Ok _ -> fail "expected Cancelled"
  | Error e -> fail e

let test_task_status_of_yojson_unknown () =
  let json = `Assoc [("status", `String "invalid_status")] in
  match Masc_domain.task_status_of_yojson json with
  | Error _ -> ()
  | Ok _ -> fail "expected Error"


(* ============================================================
   show_task_status Tests
   ============================================================ *)

let test_show_task_status_todo () =
  let s = Masc_domain.show_task_status Masc_domain.Todo in
  check bool "non-empty" true (String.length s > 0)

let test_show_task_status_claimed () =
  let status = Masc_domain.Claimed { assignee = "claude"; claimed_at = "2024-01-01" } in
  let s = Masc_domain.show_task_status status in
  check bool "contains assignee" true
    (try let _ = Str.search_forward (Str.regexp "claude") s 0 in true
     with Not_found -> false)

(* ============================================================
   string_of_agent_status Tests
   ============================================================ *)

let test_string_of_agent_status () =
  (* string_of_agent_status is alias for agent_status_to_string *)
  check string "alias works" "active" (Masc_domain.string_of_agent_status Masc_domain.Active)

(* ============================================================
   string_of_task_status Tests
   ============================================================ *)

let test_string_of_task_status () =
  (* string_of_task_status is alias for task_status_to_string *)
  check string "alias works" "todo" (Masc_domain.string_of_task_status Masc_domain.Todo)

(* ============================================================
   tempo_mode Tests
   ============================================================ *)

let test_tempo_mode_to_string_normal () =
  check string "normal" "normal" (Masc_domain.tempo_mode_to_string Masc_domain.Normal)

let test_tempo_mode_to_string_slow () =
  check string "slow" "slow" (Masc_domain.tempo_mode_to_string Masc_domain.Slow)

let test_tempo_mode_to_string_fast () =
  check string "fast" "fast" (Masc_domain.tempo_mode_to_string Masc_domain.Fast)

let test_tempo_mode_to_string_paused () =
  check string "paused" "paused" (Masc_domain.tempo_mode_to_string Masc_domain.Paused)

let test_string_of_tempo_mode () =
  (* Alias for tempo_mode_to_string *)
  check string "alias" "normal" (Masc_domain.string_of_tempo_mode Masc_domain.Normal)

let test_tempo_mode_of_string_normal () =
  match Masc_domain.tempo_mode_of_string "normal" with
  | Ok Masc_domain.Normal -> ()
  | _ -> fail "expected Ok Normal"

let test_tempo_mode_of_string_slow () =
  match Masc_domain.tempo_mode_of_string "slow" with
  | Ok Masc_domain.Slow -> ()
  | _ -> fail "expected Ok Slow"

let test_tempo_mode_of_string_fast () =
  match Masc_domain.tempo_mode_of_string "fast" with
  | Ok Masc_domain.Fast -> ()
  | _ -> fail "expected Ok Fast"

let test_tempo_mode_of_string_paused () =
  match Masc_domain.tempo_mode_of_string "paused" with
  | Ok Masc_domain.Paused -> ()
  | _ -> fail "expected Ok Paused"

let test_tempo_mode_of_string_unknown () =
  match Masc_domain.tempo_mode_of_string "invalid" with
  | Error e -> check bool "has error msg" true (String.length e > 0)
  | Ok _ -> fail "expected Error"

let test_tempo_mode_to_yojson_normal () =
  match Masc_domain.tempo_mode_to_yojson Masc_domain.Normal with
  | `String "normal" -> ()
  | _ -> fail "expected String normal"

let test_tempo_mode_to_yojson_paused () =
  match Masc_domain.tempo_mode_to_yojson Masc_domain.Paused with
  | `String "paused" -> ()
  | _ -> fail "expected String paused"

let test_tempo_mode_of_yojson_ok () =
  match Masc_domain.tempo_mode_of_yojson (`String "slow") with
  | Ok Masc_domain.Slow -> ()
  | _ -> fail "expected Ok Slow"

let test_tempo_mode_of_yojson_unknown () =
  match Masc_domain.tempo_mode_of_yojson (`String "xyz") with
  | Error _ -> ()
  | Ok _ -> fail "expected Error"

let test_tempo_mode_of_yojson_wrong_type () =
  match Masc_domain.tempo_mode_of_yojson (`Int 42) with
  | Error e -> check bool "has error" true (String.length e > 0)
  | Ok _ -> fail "expected Error"

(* ============================================================
   backlog Tests
   ============================================================ *)

let test_backlog_to_yojson_empty () =
  let b : Masc_domain.backlog = { tasks = []; last_updated = "2024-01-15T12:00:00Z"; version = 1 } in
  let json = Masc_domain.backlog_to_yojson b in
  match json with
  | `Assoc fields ->
    check bool "has tasks" true (List.mem_assoc "tasks" fields);
    check bool "has last_updated" true (List.mem_assoc "last_updated" fields);
    check bool "has version" true (List.mem_assoc "version" fields)
  | _ -> fail "expected Assoc"

let test_backlog_to_yojson_with_tasks () =
  let task : Masc_domain.task = {
    id = "t1";
    title = "Test task";
    description = "Test description";
    task_status = Masc_domain.Todo;
    priority = 1;
    files = [];
    created_at = "2024-01-15T12:00:00Z";
    created_by = None;
    predecessor_task_id = None;
    contract = None; handoff_context = None; cycle_count = 0; reclaim_policy = None; do_not_reclaim_reason = None;
  } in
  let b : Masc_domain.backlog = { tasks = [task]; last_updated = "2024-01-15T12:00:00Z"; version = 2 } in
  let json = Masc_domain.backlog_to_yojson b in
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "tasks" fields with
     | Some (`List [_]) -> ()
     | _ -> fail "expected tasks list with 1 item");
    (match List.assoc_opt "version" fields with
     | Some (`Int 2) -> ()
     | _ -> fail "expected version 2")
  | _ -> fail "expected Assoc"

let test_backlog_of_yojson_ok () =
  let json = `Assoc [
    ("tasks", `List []);
    ("last_updated", `String "2024-01-15T12:00:00Z");
    ("version", `Int 3);
  ] in
  match Masc_domain.backlog_of_yojson json with
  | Ok b ->
    check int "tasks empty" 0 (List.length b.tasks);
    check int "version" 3 b.version
  | Error e -> fail ("expected Ok, got: " ^ e)

let test_backlog_of_yojson_with_task () =
  let task_json = `Assoc [
    ("id", `String "task-1");
    ("title", `String "Test");
    ("description", `String "Description");
    ("status", `String "todo");
    ("priority", `Int 1);
    ("files", `List []);
    ("created_at", `String "2024-01-15T12:00:00Z");
  ] in
  let json = `Assoc [
    ("tasks", `List [task_json]);
    ("last_updated", `String "2024-01-15T12:00:00Z");
    ("version", `Int 1);
  ] in
  match Masc_domain.backlog_of_yojson json with
  | Ok b -> check int "has 1 task" 1 (List.length b.tasks)
  | Error e -> fail ("expected Ok, got: " ^ e)

let test_backlog_of_yojson_error () =
  let json = `String "not an object" in
  match Masc_domain.backlog_of_yojson json with
  | Ok b ->
    check int "tasks empty" 0 (List.length b.tasks);
    check string "last_updated defaults to empty" "" b.last_updated;
    check int "version defaults to 1" 1 b.version
  | Error e -> fail ("expected tolerant default, got: " ^ e)

let test_backlog_of_yojson_version_0_sentinel () =
  (* version=0 is a sentinel value indicating an uninitialised backlog.
     The decoder should preserve it, not reject. *)
  let json = `Assoc [
    ("tasks", `List []);
    ("last_updated", `String "2024-01-15T12:00:00Z");
    ("version", `Int 0);
  ] in
  match Masc_domain.backlog_of_yojson json with
  | Ok b ->
    check int "version preserved as 0" 0 b.version;
    check int "tasks empty" 0 (List.length b.tasks)
  | Error e -> fail ("expected Ok for version=0, got: " ^ e)

let test_backlog_of_yojson_version_negative () =
  (* Version -1 or negative is invalid; decoder should still pass it through
     as-is since the Yojson int decoder accepts any integer. *)
  let json = `Assoc [
    ("tasks", `List []);
    ("last_updated", `String "2024-01-15T12:00:00Z");
    ("version", `Int (-1));
  ] in
  match Masc_domain.backlog_of_yojson json with
  | Ok b -> check int "version preserved as -1" (-1) b.version
  | Error e -> fail ("expected Ok for version=-1, got: " ^ e)

let test_backlog_of_yojson_missing_version () =
  (* Missing version field should default to 1 *)
  let json = `Assoc [
    ("tasks", `List []);
    ("last_updated", `String "2024-01-15T12:00:00Z");
  ] in
  match Masc_domain.backlog_of_yojson json with
  | Ok b -> check int "version defaults to 1" 1 b.version
  | Error e -> fail ("expected Ok for missing version, got: " ^ e)

let test_backlog_of_yojson_null_version () =
  (* Null version should default to 1 (same path as missing) *)
  let json = `Assoc [
    ("tasks", `List []);
    ("last_updated", `String "2024-01-15T12:00:00Z");
    ("version", `Null);
  ] in
  match Masc_domain.backlog_of_yojson json with
  | Ok b -> check int "version defaults to 1" 1 b.version
  | Error e -> fail ("expected Ok for null version, got: " ^ e)

let test_backlog_of_yojson_missing_last_updated () =
  (* Missing last_updated should default to "" *)
  let json = `Assoc [
    ("tasks", `List []);
    ("version", `Int 1);
  ] in
  match Masc_domain.backlog_of_yojson json with
  | Ok b ->
    check string "last_updated defaults to empty" "" b.last_updated;
    check int "version preserved" 1 b.version
  | Error e -> fail ("expected Ok for missing last_updated, got: " ^ e)

let test_backlog_of_yojson_bare_tasks () =
  (* Backlog may be just {"tasks": [...]} with no metadata fields at all.
     This is the observed live format in .masc/tasks/backlog.json. *)
  let json = `Assoc [
    ("tasks", `List []);
  ] in
  match Masc_domain.backlog_of_yojson json with
  | Ok b ->
    check int "tasks empty" 0 (List.length b.tasks);
    check string "last_updated defaults to empty" "" b.last_updated;
    check int "version defaults to 1" 1 b.version
  | Error e -> fail ("expected Ok for bare tasks, got: " ^ e)

let test_backlog_of_yojson_truncated_tasks () =
  (* A valid object with "tasks" missing (truncated JSON).
     The decoder treats missing tasks key as empty array. *)
  let json = `Assoc [
    ("last_updated", `String "2024-01-15T12:00:00Z");
    ("version", `Int 1);
  ] in
  match Masc_domain.backlog_of_yojson json with
  | Ok b -> check int "tasks empty when missing" 0 (List.length b.tasks)
  | Error e -> fail ("expected Ok for missing tasks key, got: " ^ e)

let test_backlog_of_yojson_wrong_type () =
  (* Non-object input is treated like an empty object. Readers prefer a
     conservative empty backlog over failing back to a separate fallback path. *)
  let json = `Int 42 in
  match Masc_domain.backlog_of_yojson json with
  | Ok b ->
    check int "tasks empty" 0 (List.length b.tasks);
    check string "last_updated defaults to empty" "" b.last_updated;
    check int "version defaults to 1" 1 b.version
  | Error e -> fail ("expected tolerant default, got: " ^ e)

let test_backlog_of_yojson_nested_list () =
  (* Degenerate input: tasks is a non-list value. The decoder's
     match `List l -> l | _ -> [] handles this gracefully. *)
  let json = `Assoc [
    ("tasks", `String "not_a_list");
    ("last_updated", `String "2024-01-15T12:00:00Z");
    ("version", `Int 1);
  ] in
  match Masc_domain.backlog_of_yojson json with
  | Ok b -> check int "tasks empty for non-list" 0 (List.length b.tasks)
  | Error e -> fail ("expected Ok for non-list tasks, got: " ^ e)

let test_backlog_of_yojson_corrupt_task_entries () =
  (* Tasks array contains a mix of valid tasks and corrupt entries.
     The decoder uses List.filter_map to skip decode failures. *)
  let corrupt_entry = `Assoc [("id", `Int 0)] in
  let valid_entry = `Assoc [
    ("id", `String "task-1");
    ("title", `String "Valid");
    ("description", `String "Desc");
    ("status", `String "todo");
    ("priority", `Int 1);
    ("files", `List []);
    ("created_at", `String "2024-01-15T12:00:00Z");
  ] in
  let json = `Assoc [
    ("tasks", `List [corrupt_entry; valid_entry; corrupt_entry]);
    ("last_updated", `String "2024-01-15T12:00:00Z");
    ("version", `Int 1);
  ] in
  match Masc_domain.backlog_of_yojson json with
  | Ok b -> check int "1 valid task survives corruption" 1 (List.length b.tasks)
  | Error e -> fail ("expected Ok with corrupt entries, got: " ^ e)

(* ============================================================
   masc_error_to_string Tests
   ============================================================ *)

let test_masc_error_not_initialized () =
  let s = Masc_domain.masc_error_to_string (Masc_domain.System Masc_domain.System_error.NotInitialized) in
  check bool "contains not initialized" true (String.length s > 0)

let test_masc_error_already_initialized () =
  let s = Masc_domain.masc_error_to_string (Masc_domain.System Masc_domain.System_error.AlreadyInitialized) in
  check bool "contains already" true (String.length s > 0)

let test_masc_error_agent_not_found () =
  let s = Masc_domain.masc_error_to_string (Masc_domain.Agent (Masc_domain.Agent_error.NotFound "claude")) in
  check bool "contains claude" true
    (try let _ = Str.search_forward (Str.regexp "claude") s 0 in true
     with Not_found -> false)

let test_masc_error_task_not_found () =
  let s = Masc_domain.masc_error_to_string (Masc_domain.Task (Masc_domain.Task_error.NotFound "task-1")) in
  check bool "contains task-1" true
    (try let _ = Str.search_forward (Str.regexp "task-1") s 0 in true
     with Not_found -> false)

let test_masc_error_task_already_claimed () =
  let s = Masc_domain.masc_error_to_string (Masc_domain.Task (Masc_domain.Task_error.AlreadyClaimed { task_id = "t1"; by = "agent" })) in
  check bool "contains owner guidance" true
    (try let _ = Str.search_forward (Str.regexp "currently owned by agent") s 0 in true
     with Not_found -> false)

let test_masc_error_rate_limit () =
  let s = Masc_domain.masc_error_to_string
    (Masc_domain.RateLimitExceeded { limit = 100; current = 101; wait_seconds = 5; category = Masc_domain.GeneralLimit }) in
  check bool "contains limit" true (String.length s > 0)

(* ============================================================
   agent_role Tests
   ============================================================ *)

let test_agent_role_to_string_worker () =
  check string "worker" "worker" (Masc_domain.agent_role_to_string Masc_domain.Worker)

let test_agent_role_to_string_admin () =
  check string "admin" "admin" (Masc_domain.agent_role_to_string Masc_domain.Admin)

let test_agent_role_of_string_worker () =
  match Masc_domain.agent_role_of_string "worker" with
  | Ok Masc_domain.Worker -> ()
  | _ -> fail "expected Ok Worker"

let test_agent_role_of_string_admin () =
  match Masc_domain.agent_role_of_string "admin" with
  | Ok Masc_domain.Admin -> ()
  | _ -> fail "expected Ok Admin"

let test_agent_role_of_string_unknown () =
  match Masc_domain.agent_role_of_string "superuser" with
  | Error _ -> ()
  | Ok _ -> fail "expected Error"

let test_agent_role_to_yojson () =
  match Masc_domain.agent_role_to_yojson Masc_domain.Worker with
  | `String "worker" -> ()
  | _ -> fail "expected String worker"

let test_agent_role_of_yojson_ok () =
  match Masc_domain.agent_role_of_yojson (`String "admin") with
  | Ok Masc_domain.Admin -> ()
  | _ -> fail "expected Ok Admin"

let test_agent_role_of_yojson_wrong_type () =
  match Masc_domain.agent_role_of_yojson (`Int 1) with
  | Error _ -> ()
  | Ok _ -> fail "expected Error"

(* ============================================================
   agent_credential Tests
   ============================================================ *)

let test_agent_credential_to_yojson () =
  let cred : Masc_domain.agent_credential = {
    id = None;
    agent_id = None;
    agent_name = "claude";
    token = "abc123";
    role = Masc_domain.Worker;
    created_at = "2024-01-15T12:00:00Z";
    expires_at = None;
  } in
  let json = Masc_domain.agent_credential_to_yojson cred in
  match json with
  | `Assoc fields ->
    check bool "has agent_name" true (List.mem_assoc "agent_name" fields);
    check bool "has token" true (List.mem_assoc "token" fields);
    check bool "has admin" true (List.mem_assoc "admin" fields)
  | _ -> fail "expected Assoc"

let test_agent_credential_to_yojson_with_expiry () =
  let cred : Masc_domain.agent_credential = {
    id = None;
    agent_id = None;
    agent_name = "claude";
    token = "abc123";
    role = Masc_domain.Admin;
    created_at = "2024-01-15T12:00:00Z";
    expires_at = Some "2024-01-16T12:00:00Z";
  } in
  let json = Masc_domain.agent_credential_to_yojson cred in
  match json with
  | `Assoc fields -> check bool "has expires_at" true (List.mem_assoc "expires_at" fields)
  | _ -> fail "expected Assoc"

let test_agent_credential_of_yojson_ok () =
  let json = `Assoc [
    ("agent_name", `String "gemini");
    ("token", `String "xyz");
    ("admin", `Bool false);
    ("created_at", `String "2024-01-15T12:00:00Z");
  ] in
  match Masc_domain.agent_credential_of_yojson json with
  | Ok cred ->
    check string "agent_name" "gemini" cred.agent_name;
    check bool "admin=false maps to worker" true (cred.role = Masc_domain.Worker)
  | Error e -> fail ("expected Ok, got: " ^ e)

let test_agent_credential_of_yojson_error () =
  let json = `String "not an object" in
  match Masc_domain.agent_credential_of_yojson json with
  | Ok cred ->
    check string "agent_name defaults empty" "" cred.agent_name;
    check string "token defaults empty" "" cred.token;
    check bool "role defaults worker" true (cred.role = Masc_domain.Worker)
  | Error e -> fail ("expected tolerant default, got: " ^ e)

(* Regression: live fleet credential files stored role as a string field
   (["role": "admin"|"worker"]) while the original parser only inspected
   the legacy bool field (["admin"]). Missing lookup silently downgraded
   admin credentials to Worker, producing Forbidden on CanAdmin tools
   such as masc_board_delete for janitor / dashboard / qa-king. The
   parser now reads the canonical string first, falling back to the
   legacy bool. *)
let test_agent_credential_of_yojson_role_string_admin () =
  let json = `Assoc [
    ("agent_name", `String "janitor");
    ("token", `String "t");
    ("role", `String "admin");
    ("created_at", `String "2026-04-23T12:50:47Z");
  ] in
  match Masc_domain.agent_credential_of_yojson json with
  | Ok cred ->
    check bool "role:\"admin\" parses to Admin" true (cred.role = Masc_domain.Admin)
  | Error e -> fail ("expected Ok, got: " ^ e)

let test_agent_credential_of_yojson_role_string_worker () =
  let json = `Assoc [
    ("agent_name", `String "nick0cave");
    ("token", `String "t");
    ("role", `String "worker");
    ("created_at", `String "2026-04-23T08:07:00Z");
  ] in
  match Masc_domain.agent_credential_of_yojson json with
  | Ok cred ->
    check bool "role:\"worker\" parses to Worker" true (cred.role = Masc_domain.Worker)
  | Error e -> fail ("expected Ok, got: " ^ e)

let test_agent_credential_of_yojson_role_string_wins_over_admin_bool () =
  (* If a file has both fields, the canonical string wins. This covers the
     transitional period where writers emit both. *)
  let json = `Assoc [
    ("agent_name", `String "mixed");
    ("token", `String "t");
    ("role", `String "admin");
    ("admin", `Bool false);
    ("created_at", `String "2026-04-23T00:00:00Z");
  ] in
  match Masc_domain.agent_credential_of_yojson json with
  | Ok cred ->
    check bool "role string wins" true (cred.role = Masc_domain.Admin)
  | Error e -> fail ("expected Ok, got: " ^ e)

let test_agent_credential_of_yojson_admin_bool_legacy () =
  (* Older admin.json files use only the bool field; must still parse. *)
  let json = `Assoc [
    ("agent_name", `String "admin");
    ("token", `String "t");
    ("admin", `Bool true);
    ("created_at", `String "2026-04-24T01:00:11Z");
  ] in
  match Masc_domain.agent_credential_of_yojson json with
  | Ok cred ->
    check bool "admin:true legacy parses to Admin" true (cred.role = Masc_domain.Admin)
  | Error e -> fail ("expected Ok, got: " ^ e)

let test_agent_credential_of_yojson_unknown_role_fails_closed () =
  (* Fail-closed: unknown role strings return Error, never silently downgrade. *)
  let json = `Assoc [
    ("agent_name", `String "evil");
    ("token", `String "t");
    ("role", `String "root");
    ("created_at", `String "2026-04-23T00:00:00Z");
  ] in
  match Masc_domain.agent_credential_of_yojson json with
  | Error _ -> ()
  | Ok _ -> fail "expected Error for unknown role"

let test_agent_credential_to_yojson_emits_role_and_admin () =
  (* Writer emits both fields during the transition so downstream readers
     in either vintage see a consistent role. *)
  let cred : Masc_domain.agent_credential = {
    id = None;
    agent_id = None;
    agent_name = "dual";
    token = "t";
    role = Masc_domain.Admin;
    created_at = "2026-04-23T00:00:00Z";
    expires_at = None;
  } in
  match Masc_domain.agent_credential_to_yojson cred with
  | `Assoc fields ->
    check bool "has role" true (List.mem_assoc "role" fields);
    check bool "has admin" true (List.mem_assoc "admin" fields);
    let role_val = List.assoc "role" fields in
    let admin_val = List.assoc "admin" fields in
    check bool "role=\"admin\"" true (role_val = `String "admin");
    check bool "admin=true" true (admin_val = `Bool true)
  | _ -> fail "expected Assoc"

(* ============================================================
   auth_config Tests
   ============================================================ *)

let test_auth_config_to_yojson () =
  let config = Masc_domain.default_auth_config in
  let json = Masc_domain.auth_config_to_yojson config in
  match json with
  | `Assoc fields ->
    check bool "has enabled" true (List.mem_assoc "enabled" fields);
    check bool "omits default_role" false (List.mem_assoc "default_role" fields)
  | _ -> fail "expected Assoc"

let test_auth_config_of_yojson_ok () =
  let json = `Assoc [
    ("enabled", `Bool true);
    ("workspace_secret_hash", `Null);
    ("require_token", `Bool false);
    ("token_expiry_hours", `Int 48);
  ] in
  match Masc_domain.auth_config_of_yojson json with
  | Ok config ->
    check bool "enabled" true config.enabled;
    check int "expiry" 48 config.token_expiry_hours
  | Error e -> fail ("expected Ok, got: " ^ e)

let test_auth_config_of_yojson_error () =
  let json = `Int 42 in
  match Masc_domain.auth_config_of_yojson json with
  | Ok config ->
    check bool "enabled defaults true" true config.enabled;
    check bool "require_token defaults false" false config.require_token;
    check int "expiry defaults 24" 24 config.token_expiry_hours
  | Error e -> fail ("expected tolerant default, got: " ^ e)

(* ============================================================
   permissions Tests
   ============================================================ *)

let test_permissions_for_role_worker () =
  let perms = Masc_domain.permissions_for_role Masc_domain.Worker in
  check bool "has CanReadState" true (List.mem Masc_domain.CanReadState perms);
  check bool "has CanClaimTask" true (List.mem Masc_domain.CanClaimTask perms);
  check bool "has CanBroadcast" true (List.mem Masc_domain.CanBroadcast perms)

let test_permissions_for_role_admin () =
  let perms = Masc_domain.permissions_for_role Masc_domain.Admin in
  check bool "has CanInit" true (List.mem Masc_domain.CanInit perms);
  check bool "has CanReset" true (List.mem Masc_domain.CanReset perms)

let test_has_permission_worker () =
  check bool "worker can read" true (Masc_domain.has_permission Masc_domain.Worker Masc_domain.CanReadState);
  check bool "worker can broadcast" true (Masc_domain.has_permission Masc_domain.Worker Masc_domain.CanBroadcast);
  check bool "worker cannot admin" false (Masc_domain.has_permission Masc_domain.Worker Masc_domain.CanAdmin);
  check bool "worker cannot reset" false (Masc_domain.has_permission Masc_domain.Worker Masc_domain.CanReset)

let test_has_permission_admin () =
  check bool "admin can init" true (Masc_domain.has_permission Masc_domain.Admin Masc_domain.CanInit);
  check bool "admin can admin" true (Masc_domain.has_permission Masc_domain.Admin Masc_domain.CanAdmin)

(* ============================================================
   rate_limit role integration Tests
   ============================================================ *)

let test_multiplier_for_role () =
  let config : Masc_domain.rate_limit_config = {
    per_minute = 60;
    burst_allowed = 10;
    priority_agents = [];
    worker_multiplier = 1.0;
    admin_multiplier = 2.0;
    broadcast_per_minute = 30;
    task_ops_per_minute = 100;
  } in
  check (float 0.01) "worker mult" 1.0 (Masc_domain.multiplier_for_role config Masc_domain.Worker);
  check (float 0.01) "admin mult" 2.0 (Masc_domain.multiplier_for_role config Masc_domain.Admin)

let test_effective_limit () =
  let config : Masc_domain.rate_limit_config = {
    per_minute = 60;
    burst_allowed = 10;
    priority_agents = [];
    worker_multiplier = 1.0;
    admin_multiplier = 2.0;
    broadcast_per_minute = 30;
    task_ops_per_minute = 100;
  } in
  check int "worker general" 60 (Masc_domain.effective_limit config ~role:Masc_domain.Worker ~category:Masc_domain.GeneralLimit);
  check int "admin general" 120 (Masc_domain.effective_limit config ~role:Masc_domain.Admin ~category:Masc_domain.GeneralLimit)

(* ============================================================
   limit_for_category Tests
   ============================================================ *)

let test_limit_for_category_general () =
  let config : Masc_domain.rate_limit_config = {
    per_minute = 60;
    burst_allowed = 10;
    priority_agents = [];
    worker_multiplier = 1.0;
    admin_multiplier = 1.0;
    broadcast_per_minute = 30;
    task_ops_per_minute = 100;
  } in
  check int "general" 60 (Masc_domain.limit_for_category config Masc_domain.GeneralLimit)

let test_limit_for_category_broadcast () =
  let config : Masc_domain.rate_limit_config = {
    per_minute = 60;
    burst_allowed = 10;
    priority_agents = [];
    worker_multiplier = 1.0;
    admin_multiplier = 1.0;
    broadcast_per_minute = 30;
    task_ops_per_minute = 100;
  } in
  check int "broadcast" 30 (Masc_domain.limit_for_category config Masc_domain.BroadcastLimit)

let test_limit_for_category_task_ops () =
  let config : Masc_domain.rate_limit_config = {
    per_minute = 60;
    burst_allowed = 10;
    priority_agents = [];
    worker_multiplier = 1.0;
    admin_multiplier = 1.0;
    broadcast_per_minute = 30;
    task_ops_per_minute = 100;
  } in
  check int "task_ops" 100 (Masc_domain.limit_for_category config Masc_domain.TaskOpsLimit)

(* ============================================================
   category_for_tool Tests
   ============================================================ *)

let test_category_for_tool_broadcast () =
  check bool "masc_broadcast" true (Masc_domain.category_for_tool "masc_broadcast" = Masc_domain.BroadcastLimit)
  (* masc_listen removed: tool pruned *)

let test_category_for_tool_task_ops () =
  check bool "masc_add_task" true (Masc_domain.category_for_tool "masc_add_task" = Masc_domain.TaskOpsLimit);
  check bool "masc_transition" true (Masc_domain.category_for_tool "masc_transition" = Masc_domain.TaskOpsLimit)

(* Regression guard for #8873: plan-slot writes must share the
   TaskOpsLimit (30/min) bucket with the other per-task ops, not fall
   through to GeneralLimit (10/min). *)
let test_category_for_tool_plan_slot_writes () =
  check bool "masc_plan_set_task" true
    (Masc_domain.category_for_tool "masc_plan_set_task" = Masc_domain.TaskOpsLimit);
  check bool "masc_plan_clear_task" true
    (Masc_domain.category_for_tool "masc_plan_clear_task" = Masc_domain.TaskOpsLimit)

let test_category_for_tool_general () =
  check bool "masc_status" true (Masc_domain.category_for_tool "masc_status" = Masc_domain.GeneralLimit);
  check bool "unknown" true (Masc_domain.category_for_tool "unknown_tool" = Masc_domain.GeneralLimit);
  (* masc_batch_add_tasks intentionally stays in GeneralLimit until a
     maintainer call on batch rate-limiting (#8873). *)
  check bool "masc_batch_add_tasks" true
    (Masc_domain.category_for_tool "masc_batch_add_tasks" = Masc_domain.GeneralLimit)

(* ============================================================
   more masc_error_to_string Tests (coverage for all variants)
   ============================================================ *)

let test_masc_error_agent_invalid_name () =
  let s =
    Masc_domain.masc_error_to_string
      (Masc_domain.Agent (Masc_domain.Agent_error.InvalidName "agent1"))
  in
  check bool "nonempty" true (String.length s > 0)

let test_masc_error_task_not_claimed () =
  let s = Masc_domain.masc_error_to_string (Masc_domain.Task (Masc_domain.Task_error.NotClaimed "t1")) in
  check bool "contains claim guidance" true
    (try let _ = Str.search_forward (Str.regexp "Claim/start it first") s 0 in true
     with Not_found -> false)

let test_masc_error_task_invalid_state () =
  let s = Masc_domain.masc_error_to_string (Masc_domain.Task (Masc_domain.Task_error.InvalidState "cancelled")) in
  check bool "nonempty" true (String.length s > 0)

let test_masc_error_invalid_json () =
  let s = Masc_domain.masc_error_to_string (Masc_domain.System (Masc_domain.System_error.InvalidJson "bad json")) in
  check bool "nonempty" true (String.length s > 0)

let test_masc_error_io_error () =
  let s = Masc_domain.masc_error_to_string (Masc_domain.System (Masc_domain.System_error.IoError "read failed")) in
  check bool "nonempty" true (String.length s > 0)

let test_masc_error_invalid_agent_name () =
  let s = Masc_domain.masc_error_to_string (Masc_domain.Agent (Masc_domain.Agent_error.InvalidName "bad name")) in
  check bool "nonempty" true (String.length s > 0)

let test_masc_error_invalid_task_id () =
  let s = Masc_domain.masc_error_to_string (Masc_domain.Task (Masc_domain.Task_error.InvalidId "bad id")) in
  check bool "nonempty" true (String.length s > 0)

let test_masc_error_invalid_file_path () =
  let s = Masc_domain.masc_error_to_string (Masc_domain.System (Masc_domain.System_error.InvalidFilePath "bad path")) in
  check bool "nonempty" true (String.length s > 0)

let test_masc_error_unauthorized () =
  let s = Masc_domain.masc_error_to_string (Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized
    { reason = Missing_token; message = "missing token" })) in
  check bool "nonempty" true (String.length s > 0)

let test_masc_error_forbidden () =
  let s = Masc_domain.masc_error_to_string (Masc_domain.Auth (Masc_domain.Auth_error.Forbidden { agent = "a1"; action = "reset" })) in
  check bool "nonempty" true (String.length s > 0)

let test_masc_error_token_expired () =
  let s = Masc_domain.masc_error_to_string (Masc_domain.Auth (Masc_domain.Auth_error.TokenExpired "agent")) in
  check bool "nonempty" true (String.length s > 0)

let test_masc_error_invalid_token () =
  let s = Masc_domain.masc_error_to_string (Masc_domain.Auth (Masc_domain.Auth_error.InvalidToken "bad token")) in
  check bool "nonempty" true (String.length s > 0)

(* ============================================================
   default_tempo_config Tests
   ============================================================ *)

let test_default_tempo_config_mode () =
  let c = Masc_domain.default_tempo_config in
  check string "mode normal" "normal" (Masc_domain.tempo_mode_to_string c.mode)

let test_default_tempo_config_delay () =
  let c = Masc_domain.default_tempo_config in
  check int "delay_ms" 0 c.delay_ms

let test_default_tempo_config_reason () =
  let c = Masc_domain.default_tempo_config in
  check (option string) "reason none" None c.reason

(* ============================================================
   tempo_config_to/of_yojson Tests
   ============================================================ *)

let test_tempo_config_to_yojson () =
  let c : Masc_domain.tempo_config = {
    mode = Masc_domain.Slow;
    delay_ms = 100;
    reason = Some "testing";
    set_by = Some "claude";
    set_at = Some "2024-01-15T12:00:00Z";
  } in
  let json = Masc_domain.tempo_config_to_yojson c in
  match json with
  | `Assoc fields ->
    check bool "has mode" true (List.mem_assoc "mode" fields);
    check bool "has delay_ms" true (List.mem_assoc "delay_ms" fields)
  | _ -> fail "expected Assoc"

let test_tempo_config_of_yojson_ok () =
  let json = `Assoc [
    ("mode", `String "fast");
    ("delay_ms", `Int 50);
    ("reason", `String "quick work");
    ("set_by", `Null);
    ("set_at", `Null);
  ] in
  match Masc_domain.tempo_config_of_yojson json with
  | Ok c ->
    check string "mode" "fast" (Masc_domain.tempo_mode_to_string c.mode);
    check int "delay_ms" 50 c.delay_ms
  | Error e -> fail ("expected Ok: " ^ e)

let test_tempo_config_of_yojson_error () =
  let json = `Assoc [("mode", `String "invalid_mode")] in
  match Masc_domain.tempo_config_of_yojson json with
  | Error _ -> ()
  | Ok _ -> fail "expected Error"

(* ============================================================
   default_rate_limit Tests
   ============================================================ *)

let test_default_rate_limit_per_minute () =
  let c = Masc_domain.default_rate_limit in
  check int "per_minute" 10 c.per_minute

let test_default_rate_limit_burst () =
  let c = Masc_domain.default_rate_limit in
  check int "burst_allowed" 5 c.burst_allowed

let test_default_rate_limit_multipliers () =
  let c = Masc_domain.default_rate_limit in
  check (float 0.01) "worker" 1.0 c.worker_multiplier;
  check (float 0.01) "admin" 2.0 c.admin_multiplier

(* ============================================================
   rate_limit_config_to/of_yojson Tests
   ============================================================ *)

let test_rate_limit_config_to_yojson () =
  let c : Masc_domain.rate_limit_config = {
    per_minute = 60;
    burst_allowed = 10;
    priority_agents = ["claude"; "gemini"];
    worker_multiplier = 1.0;
    admin_multiplier = 2.0;
    broadcast_per_minute = 30;
    task_ops_per_minute = 100;
  } in
  let json = Masc_domain.rate_limit_config_to_yojson c in
  match json with
  | `Assoc fields ->
    check bool "has per_minute" true (List.mem_assoc "per_minute" fields);
    check bool "has priority_agents" true (List.mem_assoc "priority_agents" fields)
  | _ -> fail "expected Assoc"

let test_rate_limit_config_of_yojson_ok () =
  let json = `Assoc [
    ("per_minute", `Int 120);
    ("burst_allowed", `Int 20);
    ("priority_agents", `List [`String "admin"]);
    ("worker_multiplier", `Float 1.5);
    ("admin_multiplier", `Float 3.0);
    ("broadcast_per_minute", `Int 60);
    ("task_ops_per_minute", `Int 200);
  ] in
  match Masc_domain.rate_limit_config_of_yojson json with
  | Ok c ->
    check int "per_minute" 120 c.per_minute;
    check int "broadcast_per_minute" 60 c.broadcast_per_minute
  | Error e -> fail ("expected Ok: " ^ e)

let test_rate_limit_config_of_yojson_defaults () =
  let json = `Assoc [] in
  match Masc_domain.rate_limit_config_of_yojson json with
  | Ok c ->
    check int "default per_minute" 10 c.per_minute
  | Error e -> fail ("expected Ok with defaults: " ^ e)

(* ============================================================
   tool_result_to_yojson Tests
   ============================================================ *)

let test_tool_result_to_yojson_success () =
  let r : Masc_domain.tool_result = {
    success = true;
    message = "Operation completed";
    data = None;
  } in
  let json = Masc_domain.tool_result_to_yojson r in
  match json with
  | `Assoc fields ->
    check bool "has success" true (List.mem_assoc "success" fields);
    check bool "has message" true (List.mem_assoc "message" fields)
  | _ -> fail "expected Assoc"

let test_tool_result_to_yojson_with_data () =
  let r : Masc_domain.tool_result = {
    success = false;
    message = "Error occurred";
    data = Some (`Assoc [("error_code", `Int 500)]);
  } in
  let json = Masc_domain.tool_result_to_yojson r in
  match json with
  | `Assoc fields ->
    check bool "has data" true (List.mem_assoc "data" fields)
  | _ -> fail "expected Assoc"

(* ============================================================
   task_to/of_yojson Tests
   ============================================================ *)

let test_task_to_yojson () =
  let t : Masc_domain.task = {
    id = "task-001";
    title = "Test Task";
    description = "A test task";
    task_status = Masc_domain.Todo;
    priority = 2;
    files = ["file1.ml"; "file2.ml"];
    created_at = "2024-01-15T12:00:00Z";
    created_by = None;
    predecessor_task_id = None;
    contract = None; handoff_context = None; cycle_count = 0; reclaim_policy = None; do_not_reclaim_reason = None;
  } in
  let json = Masc_domain.task_to_yojson t in
  match json with
  | `Assoc fields ->
    check bool "has id" true (List.mem_assoc "id" fields);
    check bool "has title" true (List.mem_assoc "title" fields);
    check bool "has files" true (List.mem_assoc "files" fields)
  | _ -> fail "expected Assoc"


let test_task_of_yojson_ok () =
  let json = `Assoc [
    ("id", `String "task-003");
    ("title", `String "Parse Task");
    ("description", `String "desc");
    ("status", `String "todo");
    ("priority", `Int 3);
    ("files", `List [`String "a.ml"]);
    ("created_at", `String "2024-01-15T12:00:00Z");
  ] in
  match Masc_domain.task_of_yojson json with
  | Ok t ->
    check string "id" "task-003" t.id;
    check string "title" "Parse Task" t.title
  | Error e -> fail ("expected Ok: " ^ e)

let test_task_of_yojson_error () =
  let json = `Assoc [("id", `String "bad")] in
  match Masc_domain.task_of_yojson json with
  | Error _ -> ()
  | Ok _ -> fail "expected Error (missing title)"

let test_task_reclaim_gate_ignores_free_text_without_policy () =
  let t : Masc_domain.task = {
    id = "task-004";
    title = "Retryable task";
    description = "";
    task_status = Masc_domain.Todo;
    priority = 1;
    files = [];
    created_at = "2024-01-15T12:00:00Z";
    created_by = None;
    predecessor_task_id = None;
    contract = None;
    handoff_context = None;
    cycle_count = 9;
    reclaim_policy = None;
    do_not_reclaim_reason = Some "worktree path not found";
  } in
  match Masc_domain.task_claim_decision t with
  | Masc_domain.Claim_available Masc_domain.Claim_ready -> ()
  | Masc_domain.Claim_unavailable (Masc_domain.Claim_block_not_todo _) ->
    fail "do_not_reclaim_reason should not influence claim readiness"

let test_task_reclaim_gate_blocks_only_typed_policy () =
  let t : Masc_domain.task = {
    id = "task-005";
    title = "Terminal task";
    description = "";
    task_status = Masc_domain.Todo;
    priority = 1;
    files = [];
    created_at = "2024-01-15T12:00:00Z";
    created_by = None;
    predecessor_task_id = None;
    contract = None;
    handoff_context = None;
    cycle_count = 0;
    reclaim_policy = Some Masc_domain.Block_reclaim;
    do_not_reclaim_reason = Some "operator hard stop";
  } in
  match Masc_domain.task_claim_decision t with
  | Masc_domain.Claim_available Masc_domain.Claim_ready -> ()
  | Masc_domain.Claim_unavailable (Masc_domain.Claim_block_not_todo _) ->
    fail "claim-ready task must stay claimable regardless of reclaim policy"




let test_task_claim_next_action_todo_policy_block_still_claims () =
  (* task-1869 (#23661): a Todo task carrying a reclaim_policy stays
     claimable. RFC-0323 G-10 (#23731) then retired the typed reclaim claim
     gate entirely — [Claim_block_reclaim_policy] no longer exists, so the
     only skip reason left is [Claim_block_not_todo]; this pin survives as
     the Todo-always-claimable half. *)
  let t : Masc_domain.task = {
    id = "task-009";
    title = "Operator stop";
    description = "";
    task_status = Masc_domain.Todo;
    priority = 1;
    files = [];
    created_at = "2024-01-15T12:00:00Z";
    created_by = None;
    predecessor_task_id = None;
    contract = None;
    handoff_context = None;
    cycle_count = 0;
    reclaim_policy = Some Masc_domain.Block_reclaim;
    do_not_reclaim_reason = Some "operator hard stop";
  } in
  match Masc_domain.task_claim_next_action t with
  | Masc_domain.Claim_now ->
    check bool "claimable" true (Masc_domain.task_claim_next_action_is_claimable t)
  | Masc_domain.Skip_claim (Masc_domain.Claim_block_not_todo _) ->
    fail "todo task should not be classified as not-todo"

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Types Coverage" [
    "agent_id", [
      test_case "of_string" `Quick test_agent_id_of_string;
      test_case "equal same" `Quick test_agent_id_equal_same;
      test_case "equal diff" `Quick test_agent_id_equal_diff;
      test_case "to_yojson" `Quick test_agent_id_to_yojson;
      test_case "of_yojson ok" `Quick test_agent_id_of_yojson_ok;
      test_case "of_yojson err" `Quick test_agent_id_of_yojson_err;
      test_case "empty" `Quick test_agent_id_empty;
      test_case "special chars" `Quick test_agent_id_special_chars;
    ];
    "task_id", [
      test_case "of_string" `Quick test_task_id_of_string;
      test_case "equal same" `Quick test_task_id_equal_same;
      test_case "equal diff" `Quick test_task_id_equal_diff;
      test_case "generate" `Quick test_task_id_generate;
      test_case "generate unique" `Quick test_task_id_generate_unique;
      test_case "to_yojson" `Quick test_task_id_to_yojson;
      test_case "of_yojson ok" `Quick test_task_id_of_yojson_ok;
      test_case "of_yojson err" `Quick test_task_id_of_yojson_err;
    ];
    "execution_id", [
      test_case "generate prefix" `Quick test_execution_id_generate_prefix;
      test_case "generate unique" `Quick test_execution_id_generate_unique;
      test_case "mint order sorts" `Quick test_execution_id_mint_order_sorts;
      test_case "yojson roundtrip" `Quick test_execution_id_yojson_roundtrip;
      test_case "of_yojson rejects non-string" `Quick
        test_execution_id_of_yojson_rejects_non_string;
    ];
    "timestamp", [
      test_case "now_iso format" `Quick test_now_iso_format;
      test_case "parse valid" `Quick test_parse_iso8601_valid;
      test_case "parse invalid" `Quick test_parse_iso8601_invalid;
      test_case "parse empty" `Quick test_parse_iso8601_empty;
    ];
    "agent_status_show", [
      test_case "active" `Quick test_show_agent_status_active;
      test_case "busy" `Quick test_show_agent_status_busy;
      test_case "listening" `Quick test_show_agent_status_listening;
      test_case "inactive" `Quick test_show_agent_status_inactive;
    ];
    "agent_status_to_string", [
      test_case "active" `Quick test_agent_status_to_string_active;
      test_case "busy" `Quick test_agent_status_to_string_busy;
      test_case "listening" `Quick test_agent_status_to_string_listening;
      test_case "inactive" `Quick test_agent_status_to_string_inactive;
    ];
    "agent_status_of_string_opt", [
      test_case "active" `Quick test_agent_status_of_string_opt_active;
      test_case "busy" `Quick test_agent_status_of_string_opt_busy;
      test_case "listening" `Quick test_agent_status_of_string_opt_listening;
      test_case "inactive" `Quick test_agent_status_of_string_opt_inactive;
      test_case "unknown" `Quick test_agent_status_of_string_opt_unknown;
    ];
    "agent_status_to_yojson", [
      test_case "active" `Quick test_agent_status_to_yojson_active;
      test_case "busy" `Quick test_agent_status_to_yojson_busy;
    ];
    "agent_status_of_yojson", [
      test_case "active" `Quick test_agent_status_of_yojson_active;
      test_case "busy" `Quick test_agent_status_of_yojson_busy;
      test_case "unknown" `Quick test_agent_status_of_yojson_unknown;
      test_case "wrong type" `Quick test_agent_status_of_yojson_wrong_type;
    ];
    "task_status_to_string", [
      test_case "todo" `Quick test_task_status_to_string_todo;
      test_case "claimed" `Quick test_task_status_to_string_claimed;
      test_case "in_progress" `Quick test_task_status_to_string_in_progress;
      test_case "done" `Quick test_task_status_to_string_done;
      test_case "cancelled" `Quick test_task_status_to_string_cancelled;
    ];
    "task_status_to_yojson", [
      test_case "todo" `Quick test_task_status_to_yojson_todo;
      test_case "claimed" `Quick test_task_status_to_yojson_claimed;
      test_case "in_progress" `Quick test_task_status_to_yojson_in_progress;
      test_case "done with notes" `Quick test_task_status_to_yojson_done_with_notes;
      test_case "done no notes" `Quick test_task_status_to_yojson_done_no_notes;
      test_case "cancelled with reason" `Quick test_task_status_to_yojson_cancelled_with_reason;
    ];
    "task_status_of_yojson", [
      test_case "todo" `Quick test_task_status_of_yojson_todo;
      test_case "claimed" `Quick test_task_status_of_yojson_claimed;
      test_case "in_progress" `Quick test_task_status_of_yojson_in_progress;
      test_case "done" `Quick test_task_status_of_yojson_done;
      test_case "cancelled" `Quick test_task_status_of_yojson_cancelled;
      test_case "unknown" `Quick test_task_status_of_yojson_unknown;
    ];
    "show_task_status", [
      test_case "todo" `Quick test_show_task_status_todo;
      test_case "claimed" `Quick test_show_task_status_claimed;
    ];
    "aliases", [
      test_case "string_of_agent_status" `Quick test_string_of_agent_status;
      test_case "string_of_task_status" `Quick test_string_of_task_status;
    ];
    "tempo_mode_to_string", [
      test_case "normal" `Quick test_tempo_mode_to_string_normal;
      test_case "slow" `Quick test_tempo_mode_to_string_slow;
      test_case "fast" `Quick test_tempo_mode_to_string_fast;
      test_case "paused" `Quick test_tempo_mode_to_string_paused;
    ];
    "string_of_tempo_mode", [
      test_case "alias" `Quick test_string_of_tempo_mode;
    ];
    "tempo_mode_of_string", [
      test_case "normal" `Quick test_tempo_mode_of_string_normal;
      test_case "slow" `Quick test_tempo_mode_of_string_slow;
      test_case "fast" `Quick test_tempo_mode_of_string_fast;
      test_case "paused" `Quick test_tempo_mode_of_string_paused;
      test_case "unknown" `Quick test_tempo_mode_of_string_unknown;
    ];
    "tempo_mode_to_yojson", [
      test_case "normal" `Quick test_tempo_mode_to_yojson_normal;
      test_case "paused" `Quick test_tempo_mode_to_yojson_paused;
    ];
    "tempo_mode_of_yojson", [
      test_case "ok" `Quick test_tempo_mode_of_yojson_ok;
      test_case "unknown" `Quick test_tempo_mode_of_yojson_unknown;
      test_case "wrong type" `Quick test_tempo_mode_of_yojson_wrong_type;
    ];
    "backlog_to_yojson", [
      test_case "empty" `Quick test_backlog_to_yojson_empty;
      test_case "with tasks" `Quick test_backlog_to_yojson_with_tasks;
    ];
    "backlog_of_yojson", [
      test_case "ok" `Quick test_backlog_of_yojson_ok;
      test_case "with task" `Quick test_backlog_of_yojson_with_task;
      test_case "error" `Quick test_backlog_of_yojson_error;
      test_case "version 0 sentinel" `Quick test_backlog_of_yojson_version_0_sentinel;
      test_case "version negative" `Quick test_backlog_of_yojson_version_negative;
      test_case "missing version" `Quick test_backlog_of_yojson_missing_version;
      test_case "null version" `Quick test_backlog_of_yojson_null_version;
      test_case "missing last_updated" `Quick test_backlog_of_yojson_missing_last_updated;
      test_case "bare tasks only" `Quick test_backlog_of_yojson_bare_tasks;
      test_case "truncated tasks" `Quick test_backlog_of_yojson_truncated_tasks;
      test_case "wrong type" `Quick test_backlog_of_yojson_wrong_type;
      test_case "nested list" `Quick test_backlog_of_yojson_nested_list;
      test_case "corrupt task entries" `Quick test_backlog_of_yojson_corrupt_task_entries;
    ];
    "masc_error_to_string", [
      test_case "not initialized" `Quick test_masc_error_not_initialized;
      test_case "already initialized" `Quick test_masc_error_already_initialized;
      test_case "agent not found" `Quick test_masc_error_agent_not_found;
      test_case "task not found" `Quick test_masc_error_task_not_found;
      test_case "task already claimed" `Quick test_masc_error_task_already_claimed;
      test_case "rate limit" `Quick test_masc_error_rate_limit;
    ];
    "agent_role_to_string", [
      test_case "worker" `Quick test_agent_role_to_string_worker;
      test_case "admin" `Quick test_agent_role_to_string_admin;
    ];
    "agent_role_of_string", [
      test_case "worker" `Quick test_agent_role_of_string_worker;
      test_case "admin" `Quick test_agent_role_of_string_admin;
      test_case "unknown" `Quick test_agent_role_of_string_unknown;
    ];
    "agent_role_yojson", [
      test_case "to_yojson" `Quick test_agent_role_to_yojson;
      test_case "of_yojson ok" `Quick test_agent_role_of_yojson_ok;
      test_case "of_yojson wrong type" `Quick test_agent_role_of_yojson_wrong_type;
    ];
    "agent_credential", [
      test_case "to_yojson" `Quick test_agent_credential_to_yojson;
      test_case "to_yojson with expiry" `Quick test_agent_credential_to_yojson_with_expiry;
      test_case "of_yojson ok" `Quick test_agent_credential_of_yojson_ok;
      test_case "of_yojson error" `Quick test_agent_credential_of_yojson_error;
      test_case "of_yojson role=\"admin\" -> Admin" `Quick
        test_agent_credential_of_yojson_role_string_admin;
      test_case "of_yojson role=\"worker\" -> Worker" `Quick
        test_agent_credential_of_yojson_role_string_worker;
      test_case "of_yojson role string wins over admin bool" `Quick
        test_agent_credential_of_yojson_role_string_wins_over_admin_bool;
      test_case "of_yojson legacy admin=true -> Admin" `Quick
        test_agent_credential_of_yojson_admin_bool_legacy;
      test_case "of_yojson unknown role fails closed to Worker" `Quick
        test_agent_credential_of_yojson_unknown_role_fails_closed;
      test_case "to_yojson emits both role and admin fields" `Quick
        test_agent_credential_to_yojson_emits_role_and_admin;
    ];
    "auth_config", [
      test_case "to_yojson" `Quick test_auth_config_to_yojson;
      test_case "of_yojson ok" `Quick test_auth_config_of_yojson_ok;
      test_case "of_yojson error" `Quick test_auth_config_of_yojson_error;
    ];
    "permissions", [
      test_case "for_role worker" `Quick test_permissions_for_role_worker;
      test_case "for_role admin" `Quick test_permissions_for_role_admin;
      test_case "has_permission worker" `Quick test_has_permission_worker;
      test_case "has_permission admin" `Quick test_has_permission_admin;
    ];
    "rate_limit_role", [
      test_case "multiplier_for_role" `Quick test_multiplier_for_role;
      test_case "effective_limit" `Quick test_effective_limit;
    ];
    "limit_for_category", [
      test_case "general" `Quick test_limit_for_category_general;
      test_case "broadcast" `Quick test_limit_for_category_broadcast;
      test_case "task_ops" `Quick test_limit_for_category_task_ops;
    ];
    "category_for_tool", [
      test_case "broadcast" `Quick test_category_for_tool_broadcast;
      test_case "task_ops" `Quick test_category_for_tool_task_ops;
      test_case "plan_slot_writes (#8873)" `Quick test_category_for_tool_plan_slot_writes;
      test_case "general" `Quick test_category_for_tool_general;
    ];
    "masc_error_extended", [
      test_case "agent invalid name" `Quick test_masc_error_agent_invalid_name;
      test_case "task not claimed" `Quick test_masc_error_task_not_claimed;
      test_case "task invalid state" `Quick test_masc_error_task_invalid_state;
      test_case "invalid json" `Quick test_masc_error_invalid_json;
      test_case "io error" `Quick test_masc_error_io_error;
      test_case "invalid agent name" `Quick test_masc_error_invalid_agent_name;
      test_case "invalid task id" `Quick test_masc_error_invalid_task_id;
      test_case "invalid file path" `Quick test_masc_error_invalid_file_path;
      test_case "unauthorized" `Quick test_masc_error_unauthorized;
      test_case "forbidden" `Quick test_masc_error_forbidden;
      test_case "token expired" `Quick test_masc_error_token_expired;
      test_case "invalid token" `Quick test_masc_error_invalid_token;
    ];
    "default_tempo_config", [
      test_case "mode" `Quick test_default_tempo_config_mode;
      test_case "delay" `Quick test_default_tempo_config_delay;
      test_case "reason" `Quick test_default_tempo_config_reason;
    ];
    "tempo_config_yojson", [
      test_case "to_yojson" `Quick test_tempo_config_to_yojson;
      test_case "of_yojson ok" `Quick test_tempo_config_of_yojson_ok;
      test_case "of_yojson error" `Quick test_tempo_config_of_yojson_error;
    ];
    "default_rate_limit", [
      test_case "per_minute" `Quick test_default_rate_limit_per_minute;
      test_case "burst" `Quick test_default_rate_limit_burst;
      test_case "multipliers" `Quick test_default_rate_limit_multipliers;
    ];
    "rate_limit_config_yojson", [
      test_case "to_yojson" `Quick test_rate_limit_config_to_yojson;
      test_case "of_yojson ok" `Quick test_rate_limit_config_of_yojson_ok;
      test_case "of_yojson defaults" `Quick test_rate_limit_config_of_yojson_defaults;
    ];
    "tool_result", [
      test_case "to_yojson success" `Quick test_tool_result_to_yojson_success;
      test_case "to_yojson with data" `Quick test_tool_result_to_yojson_with_data;
    ];
    "task_yojson", [
      test_case "to_yojson" `Quick test_task_to_yojson;
      test_case "of_yojson ok" `Quick test_task_of_yojson_ok;
      test_case "of_yojson error" `Quick test_task_of_yojson_error;
      test_case "claim next action: todo stays claimable under policy block" `Quick
        test_task_claim_next_action_todo_policy_block_still_claims;
    ];
  ]
