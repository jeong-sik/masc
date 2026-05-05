(** Comprehensive coverage tests for Types, Coord_utils, and Coord_eio modules *)

(* Initialize RNG for crypto operations *)
let () = Mirage_crypto_rng_unix.use_default ()

open Alcotest

module Types = Masc_domain

(* ============================================================ *)
(* Test Helpers                                                  *)
(* ============================================================ *)

let json_string = testable Yojson.Safe.pp Yojson.Safe.equal

let _result_ok testable_a =
  testable
    (fun fmt r ->
      match r with
      | Ok a -> Fmt.pf fmt "Ok(%a)" (Alcotest.pp testable_a) a
      | Error e -> Fmt.pf fmt "Error(%s)" e)
    (fun a b ->
      match a, b with
      | Ok x, Ok y -> Alcotest.equal testable_a x y
      | Error x, Error y -> x = y
      | _ -> false)

let is_ok result =
  match result with Ok _ -> true | Error _ -> false

let is_error result =
  match result with Ok _ -> false | Error _ -> true

(* ============================================================ *)
(* Masc_domain.Agent_id Tests                                          *)
(* ============================================================ *)

let test_agent_id_of_string () =
  let id = Masc_domain.Agent_id.of_string "claude-123" in
  check string "to_string" "claude-123" (Masc_domain.Agent_id.to_string id)

let test_agent_id_equal () =
  let a = Masc_domain.Agent_id.of_string "agent-a" in
  let b = Masc_domain.Agent_id.of_string "agent-a" in
  let c = Masc_domain.Agent_id.of_string "agent-b" in
  check bool "equal same" true (Masc_domain.Agent_id.equal a b);
  check bool "not equal different" false (Masc_domain.Agent_id.equal a c)

let test_agent_id_to_yojson () =
  let id = Masc_domain.Agent_id.of_string "test-agent" in
  let json = Masc_domain.Agent_id.to_yojson id in
  check json_string "json string" (`String "test-agent") json

let test_agent_id_of_yojson_valid () =
  let result = Masc_domain.Agent_id.of_yojson (`String "valid-agent") in
  check bool "is ok" true (is_ok result)

let test_agent_id_of_yojson_invalid () =
  let result = Masc_domain.Agent_id.of_yojson (`Int 123) in
  check bool "is error" true (is_error result)

(* ============================================================ *)
(* Masc_domain.Task_id Tests                                           *)
(* ============================================================ *)

let test_task_id_of_string () =
  let id = Masc_domain.Task_id.of_string "task-456" in
  check string "to_string" "task-456" (Masc_domain.Task_id.to_string id)

let test_task_id_equal () =
  let a = Masc_domain.Task_id.of_string "task-a" in
  let b = Masc_domain.Task_id.of_string "task-a" in
  let c = Masc_domain.Task_id.of_string "task-b" in
  check bool "equal same" true (Masc_domain.Task_id.equal a b);
  check bool "not equal different" false (Masc_domain.Task_id.equal a c)

let test_task_id_generate () =
  let id1 = Masc_domain.Task_id.generate () in
  let id2 = Masc_domain.Task_id.generate () in
  let s1 = Masc_domain.Task_id.to_string id1 in
  let s2 = Masc_domain.Task_id.to_string id2 in
  check bool "starts with task-" true (String.length s1 > 5);
  check bool "different ids" false (s1 = s2)

let test_task_id_to_yojson () =
  let id = Masc_domain.Task_id.of_string "task-test" in
  let json = Masc_domain.Task_id.to_yojson id in
  check json_string "json string" (`String "task-test") json

let test_task_id_of_yojson_valid () =
  let result = Masc_domain.Task_id.of_yojson (`String "valid-task") in
  check bool "is ok" true (is_ok result)

let test_task_id_of_yojson_invalid () =
  let result = Masc_domain.Task_id.of_yojson (`Bool true) in
  check bool "is error" true (is_error result)

(* ============================================================ *)
(* Masc_domain.Timestamp Tests                                         *)
(* ============================================================ *)

let test_now_iso_format () =
  let ts = Masc_domain.now_iso () in
  (* ISO8601 format: YYYY-MM-DDTHH:MM:SSZ *)
  check bool "length >= 20" true (String.length ts >= 20);
  check bool "contains T" true (String.contains ts 'T');
  check bool "ends with Z" true (ts.[String.length ts - 1] = 'Z')

let test_parse_iso8601_valid () =
  let ts = "2024-12-25T10:30:45Z" in
  let result = Masc_domain.parse_iso8601 ts in
  check bool "positive timestamp" true (result > 0.0)

let test_parse_iso8601_invalid () =
  let ts = "invalid-timestamp" in
  let default = 12345.0 in
  let result = Masc_domain.parse_iso8601 ~default_time:default ts in
  check (float 0.1) "uses default" default result

(* ============================================================ *)
(* Masc_domain.agent_status Tests                                      *)
(* ============================================================ *)

let test_agent_status_to_string () =
  check string "Active" "active" (Masc_domain.agent_status_to_string Masc_domain.Active);
  check string "Busy" "busy" (Masc_domain.agent_status_to_string Masc_domain.Busy);
  check string "Listening" "listening" (Masc_domain.agent_status_to_string Masc_domain.Listening);
  check string "Inactive" "inactive" (Masc_domain.agent_status_to_string Masc_domain.Inactive)

let test_agent_status_of_string_opt () =
  check bool "active Some" true (Masc_domain.agent_status_of_string_opt "active" = Some Masc_domain.Active);
  check bool "unknown None" true (Masc_domain.agent_status_of_string_opt "unknown" = None)

(* #10748: Result-based parser must not collapse unknown input to a
   default — explicit Error preserves the original string so callers
   can log/route the diagnostic instead of silently routing
   typos/future-variants to "Active". *)
let test_agent_status_of_string_r () =
  check bool "active Ok"
    true (Masc_domain.agent_status_of_string_r "active" = Ok Masc_domain.Active);
  check bool "busy Ok"
    true (Masc_domain.agent_status_of_string_r "busy" = Ok Masc_domain.Busy);
  (match Masc_domain.agent_status_of_string_r "bogus" with
   | Ok _ -> failwith "unknown input must be Error, not Ok"
   | Error msg ->
     check bool "Error preserves original input"
       true (String_util.contains_substring msg "bogus"))

let test_agent_status_to_yojson () =
  let json = Masc_domain.agent_status_to_yojson Masc_domain.Busy in
  check json_string "busy json" (`String "busy") json

let test_agent_status_of_yojson_valid () =
  let result = Masc_domain.agent_status_of_yojson (`String "listening") in
  check bool "is ok" true (is_ok result);
  match result with
  | Ok status -> check bool "is Listening" true (status = Masc_domain.Listening)
  | Error _ -> failwith "should be ok"

let test_agent_status_of_yojson_invalid () =
  let result = Masc_domain.agent_status_of_yojson (`String "garbage") in
  check bool "is error" true (is_error result)

(* ============================================================ *)
(* Masc_domain.task_status Tests                                       *)
(* ============================================================ *)

let test_task_status_todo () =
  let status = Masc_domain.Todo in
  check string "to_string" "todo" (Masc_domain.task_status_to_string status);
  let json = Masc_domain.task_status_to_yojson status in
  let result = Masc_domain.task_status_of_yojson json in
  check bool "roundtrip ok" true (is_ok result)

let test_task_status_claimed () =
  let status = Masc_domain.Claimed { assignee = "claude"; claimed_at = "2024-01-01T00:00:00Z" } in
  check string "to_string" "claimed" (Masc_domain.task_status_to_string status);
  let json = Masc_domain.task_status_to_yojson status in
  let result = Masc_domain.task_status_of_yojson json in
  check bool "roundtrip ok" true (is_ok result)

let test_task_status_in_progress () =
  let status = Masc_domain.InProgress { assignee = "gemini"; started_at = "2024-01-01T01:00:00Z" } in
  check string "to_string" "in_progress" (Masc_domain.task_status_to_string status);
  let json = Masc_domain.task_status_to_yojson status in
  let result = Masc_domain.task_status_of_yojson json in
  check bool "roundtrip ok" true (is_ok result)

let test_task_status_done () =
  let status = Masc_domain.Done {
    assignee = "codex";
    completed_at = "2024-01-01T02:00:00Z";
    notes = Some "All tests pass"
  } in
  check string "to_string" "done" (Masc_domain.task_status_to_string status);
  let json = Masc_domain.task_status_to_yojson status in
  let result = Masc_domain.task_status_of_yojson json in
  check bool "roundtrip ok" true (is_ok result)

let test_task_status_done_no_notes () =
  let status = Masc_domain.Done {
    assignee = "codex";
    completed_at = "2024-01-01T02:00:00Z";
    notes = None
  } in
  let json = Masc_domain.task_status_to_yojson status in
  let result = Masc_domain.task_status_of_yojson json in
  check bool "roundtrip ok" true (is_ok result)

let test_task_status_cancelled () =
  let status = Masc_domain.Cancelled {
    cancelled_by = "admin";
    cancelled_at = "2024-01-01T03:00:00Z";
    reason = Some "Duplicate task"
  } in
  check string "to_string" "cancelled" (Masc_domain.task_status_to_string status);
  let json = Masc_domain.task_status_to_yojson status in
  let result = Masc_domain.task_status_of_yojson json in
  check bool "roundtrip ok" true (is_ok result)

let test_task_status_of_yojson_unknown () =
  let json = `Assoc [("status", `String "unknown_status")] in
  let result = Masc_domain.task_status_of_yojson json in
  check bool "is error" true (is_error result)

(* ============================================================ *)
(* Masc_domain.tempo_mode Tests                                        *)
(* ============================================================ *)

let test_tempo_mode_to_string () =
  check string "Normal" "normal" (Masc_domain.tempo_mode_to_string Masc_domain.Normal);
  check string "Slow" "slow" (Masc_domain.tempo_mode_to_string Masc_domain.Slow);
  check string "Fast" "fast" (Masc_domain.tempo_mode_to_string Masc_domain.Fast);
  check string "Paused" "paused" (Masc_domain.tempo_mode_to_string Masc_domain.Paused)

let test_tempo_mode_of_string () =
  check bool "normal ok" true (is_ok (Masc_domain.tempo_mode_of_string "normal"));
  check bool "slow ok" true (is_ok (Masc_domain.tempo_mode_of_string "slow"));
  check bool "fast ok" true (is_ok (Masc_domain.tempo_mode_of_string "fast"));
  check bool "paused ok" true (is_ok (Masc_domain.tempo_mode_of_string "paused"));
  check bool "unknown error" true (is_error (Masc_domain.tempo_mode_of_string "turbo"))

let test_tempo_mode_roundtrip () =
  let modes = [Masc_domain.Normal; Masc_domain.Slow; Masc_domain.Fast; Masc_domain.Paused] in
  List.iter (fun mode ->
    let json = Masc_domain.tempo_mode_to_yojson mode in
    let result = Masc_domain.tempo_mode_of_yojson json in
    check bool "roundtrip ok" true (is_ok result)
  ) modes

(* ============================================================ *)
(* Masc_domain.tempo_config Tests                                      *)
(* ============================================================ *)

let test_default_tempo_config () =
  let cfg = Masc_domain.default_tempo_config in
  check bool "mode is Normal" true (cfg.mode = Masc_domain.Normal);
  check int "delay_ms is 0" 0 cfg.delay_ms;
  check bool "reason is None" true (cfg.reason = None)

let test_tempo_config_roundtrip () =
  let cfg = Masc_domain.{
    mode = Slow;
    delay_ms = 500;
    reason = Some "Heavy workload";
    set_by = Some "admin";
    set_at = Some "2024-01-01T00:00:00Z";
  } in
  let json = Masc_domain.tempo_config_to_yojson cfg in
  let result = Masc_domain.tempo_config_of_yojson json in
  check bool "roundtrip ok" true (is_ok result)

(* ============================================================ *)
(* Masc_domain.a2a_task_status Tests                                   *)
(* ============================================================ *)

let test_a2a_task_status_all () =
  let statuses = [
    (Masc_domain.A2APending, "pending");
    (Masc_domain.A2ARunning, "running");
    (Masc_domain.A2ACompleted, "completed");
    (Masc_domain.A2AFailed, "failed");
    (Masc_domain.A2ACanceled, "canceled");
  ] in
  List.iter (fun (status, expected) ->
    check string "to_string" expected (Masc_domain.a2a_task_status_to_string status);
    let json = Masc_domain.a2a_task_status_to_yojson status in
    let result = Masc_domain.a2a_task_status_of_yojson json in
    check bool "roundtrip ok" true (is_ok result)
  ) statuses

let test_a2a_task_status_of_string_unknown () =
  let result = Masc_domain.a2a_task_status_of_string "unknown" in
  check bool "is error" true (is_error result)

(* ============================================================ *)
(* Masc_domain.portal_state Tests                                      *)
(* ============================================================ *)

let test_portal_state_all () =
  let states = [(Masc_domain.PortalOpen, "open"); (Masc_domain.PortalClosed, "closed")] in
  List.iter (fun (state, expected) ->
    check string "to_string" expected (Masc_domain.portal_state_to_string state);
    let json = Masc_domain.portal_state_to_yojson state in
    let result = Masc_domain.portal_state_of_yojson json in
    check bool "roundtrip ok" true (is_ok result)
  ) states

let test_portal_state_of_string_unknown () =
  let result = Masc_domain.portal_state_of_string "half-open" in
  check bool "is error" true (is_error result)

(* ============================================================ *)
(* Masc_domain.agent_role Tests                                        *)
(* ============================================================ *)

let test_agent_role_all () =
  let roles = [(Masc_domain.Worker, "worker"); (Masc_domain.Admin, "admin")] in
  List.iter (fun (role, expected) ->
    check string "to_string" expected (Masc_domain.agent_role_to_string role);
    let json = Masc_domain.agent_role_to_yojson role in
    let result = Masc_domain.agent_role_of_yojson json in
    check bool "roundtrip ok" true (is_ok result)
  ) roles

let test_agent_role_of_string_unknown () =
  let result = Masc_domain.agent_role_of_string "superadmin" in
  check bool "is error" true (is_error result)

(* ============================================================ *)
(* Masc_domain.permissions Tests                                       *)
(* ============================================================ *)

let test_permissions_worker () =
  let perms = Masc_domain.permissions_for_role Masc_domain.Worker in
  check bool "can read" true (List.mem Masc_domain.CanReadState perms);
  check bool "can add task" true (List.mem Masc_domain.CanAddTask perms);
  check bool "can broadcast" true (List.mem Masc_domain.CanBroadcast perms);
  check bool "cannot init" false (List.mem Masc_domain.CanInit perms)

let test_permissions_admin () =
  let perms = Masc_domain.permissions_for_role Masc_domain.Admin in
  check bool "can init" true (List.mem Masc_domain.CanInit perms);
  check bool "can reset" true (List.mem Masc_domain.CanReset perms);
  check bool "can admin" true (List.mem Masc_domain.CanAdmin perms)

let test_has_permission () =
  check bool "worker can read" true (Masc_domain.has_permission Masc_domain.Worker Masc_domain.CanReadState);
  check bool "worker cannot init" false (Masc_domain.has_permission Masc_domain.Worker Masc_domain.CanInit);
  check bool "admin can init" true (Masc_domain.has_permission Masc_domain.Admin Masc_domain.CanInit)

(* ============================================================ *)
(* Masc_domain.rate_limit Tests                                        *)
(* ============================================================ *)

let test_default_rate_limit () =
  let cfg = Masc_domain.default_rate_limit in
  check int "per_minute" 10 cfg.per_minute;
  check int "burst_allowed" 5 cfg.burst_allowed;
  check (float 0.01) "worker_multiplier" 1.0 cfg.worker_multiplier;
  check (float 0.01) "admin_multiplier" 2.0 cfg.admin_multiplier

let test_limit_for_category () =
  let cfg = Masc_domain.default_rate_limit in
  check int "general" cfg.per_minute (Masc_domain.limit_for_category cfg Masc_domain.GeneralLimit);
  check int "broadcast" cfg.broadcast_per_minute (Masc_domain.limit_for_category cfg Masc_domain.BroadcastLimit);
  check int "task_ops" cfg.task_ops_per_minute (Masc_domain.limit_for_category cfg Masc_domain.TaskOpsLimit)

let test_category_for_tool () =
  check bool "broadcast" true (Masc_domain.category_for_tool "masc_broadcast" = Masc_domain.BroadcastLimit);
  check bool "status" true (Masc_domain.category_for_tool "masc_status" = Masc_domain.GeneralLimit)

let test_multiplier_for_role () =
  let cfg = Masc_domain.default_rate_limit in
  check (float 0.01) "worker" 1.0 (Masc_domain.multiplier_for_role cfg Masc_domain.Worker);
  check (float 0.01) "admin" 2.0 (Masc_domain.multiplier_for_role cfg Masc_domain.Admin)

let test_effective_limit () =
  let cfg = Masc_domain.default_rate_limit in
  let eff = Masc_domain.effective_limit cfg ~role:Masc_domain.Admin ~category:Masc_domain.GeneralLimit in
  check int "admin general" 20 eff (* 10 * 2.0 *)

let test_rate_limit_config_roundtrip () =
  let cfg = Masc_domain.{
    per_minute = 20;
    burst_allowed = 10;
    priority_agents = ["admin-1"; "admin-2"];
    worker_multiplier = 1.5;
    admin_multiplier = 3.0;
    broadcast_per_minute = 30;
    task_ops_per_minute = 60;
  } in
  let json = Masc_domain.rate_limit_config_to_yojson cfg in
  let result = Masc_domain.rate_limit_config_of_yojson json in
  check bool "roundtrip ok" true (is_ok result)

(* ============================================================ *)
(* Masc_domain.masc_error Tests                                        *)
(* ============================================================ *)

let test_masc_error_to_string () =
  check bool "NotInitialized" true
    (String.length (Masc_domain.masc_error_to_string (Masc_domain.System Masc_domain.System_error.NotInitialized)) > 0);
  check bool "AgentNotFound" true
    (String.length (Masc_domain.masc_error_to_string (Masc_domain.Agent (Masc_domain.Agent_error.NotFound "test"))) > 0);
  check bool "TaskAlreadyClaimed" true
    (String.length (Masc_domain.masc_error_to_string
      (Masc_domain.Task (Masc_domain.Task_error.AlreadyClaimed { task_id = "t1"; by = "agent" }))) > 0);
  check bool "RateLimitExceeded" true
    (String.length (Masc_domain.masc_error_to_string
      (Masc_domain.RateLimitExceeded {
        limit = 10; current = 15; wait_seconds = 30;
        category = Masc_domain.BroadcastLimit
      })) > 0)

(* ============================================================ *)
(* Masc_domain.worktree_info Tests                                     *)
(* ============================================================ *)

let test_worktree_info_roundtrip () =
  let wt = Masc_domain.{
    branch = "feature/test";
    path = ".worktrees/feature-test";
    git_root = "/home/user/project";
    repo_name = "project";
  } in
  let json = Masc_domain.worktree_info_to_yojson wt in
  let result = Masc_domain.worktree_info_of_yojson json in
  check bool "roundtrip ok" true (is_ok result)

(* ============================================================ *)
(* Masc_domain.task Tests                                              *)
(* ============================================================ *)

let test_task_roundtrip () =
  let task = Masc_domain.{
    id = "task-123";
    title = "Test Task";
    description = "A test task for coverage";
    goal_id = None;
    task_status = Todo;
    priority = 2;
    files = ["file1.ml"; "file2.ml"];
    created_at = "2024-01-01T00:00:00Z";
    worktree = None;
    created_by = None;
    stage = None;
    contract = None; handoff_context = None; cycle_count = 0; do_not_reclaim_reason = None;
  } in
  let json = Masc_domain.task_to_yojson task in
  let result = Masc_domain.task_of_yojson json in
  check bool "roundtrip ok" true (is_ok result)

let test_task_with_worktree () =
  let task = Masc_domain.{
    id = "task-456";
    title = "Worktree Task";
    description = "Task with worktree";
    task_status = InProgress { assignee = "claude"; started_at = "2024-01-01T01:00:00Z" };
    goal_id = None;
    priority = 1;
    files = [];
    created_at = "2024-01-01T00:00:00Z";
    worktree = Some {
      branch = "feature/wt";
      path = ".worktrees/wt";
      git_root = "/project";
      repo_name = "project";
    };
    created_by = None;
    stage = None;
    contract = None; handoff_context = None; cycle_count = 0; do_not_reclaim_reason = None;
  } in
  let json = Masc_domain.task_to_yojson task in
  let result = Masc_domain.task_of_yojson json in
  check bool "roundtrip ok" true (is_ok result)

(* ============================================================ *)
(* Masc_domain.backlog Tests                                           *)
(* ============================================================ *)

let test_backlog_roundtrip () =
  let backlog = Masc_domain.{
    tasks = [
      { id = "t1"; title = "Task 1"; description = "Desc 1";
        task_status = Todo; goal_id = None; priority = 1; files = [];
        created_at = "2024-01-01T00:00:00Z"; worktree = None;
        created_by = None;
        stage = None;
        contract = None; handoff_context = None; cycle_count = 0; do_not_reclaim_reason = None };
      { id = "t2"; title = "Task 2"; description = "Desc 2";
        task_status = Done { assignee = "a"; completed_at = "2024-01-02T00:00:00Z"; notes = None };
        goal_id = None; priority = 2; files = []; created_at = "2024-01-01T01:00:00Z"; worktree = None;
        created_by = None;
        stage = None;
        contract = None; handoff_context = None; cycle_count = 0; do_not_reclaim_reason = None };
    ];
    last_updated = "2024-01-02T00:00:00Z";
    version = 5;
  } in
  let json = Masc_domain.backlog_to_yojson backlog in
  let result = Masc_domain.backlog_of_yojson json in
  check bool "roundtrip ok" true (is_ok result)

(* ============================================================ *)
(* Masc_domain.a2a_task Tests                                          *)
(* ============================================================ *)

let test_a2a_task_roundtrip () =
  let task = Masc_domain.{
    a2a_id = "a2a-123";
    from_agent = "claude";
    to_agent = "gemini";
    a2a_message = "Please review this code";
    a2a_status = A2ARunning;
    a2a_result = None;
    created_at = "2024-01-01T00:00:00Z";
    updated_at = "2024-01-01T01:00:00Z";
  } in
  let json = Masc_domain.a2a_task_to_yojson task in
  let result = Masc_domain.a2a_task_of_yojson json in
  check bool "roundtrip ok" true (is_ok result)

let test_a2a_task_with_result () =
  let task = Masc_domain.{
    a2a_id = "a2a-456";
    from_agent = "gemini";
    to_agent = "codex";
    a2a_message = "Implement feature X";
    a2a_status = A2ACompleted;
    a2a_result = Some "Feature implemented successfully";
    created_at = "2024-01-01T00:00:00Z";
    updated_at = "2024-01-01T02:00:00Z";
  } in
  let json = Masc_domain.a2a_task_to_yojson task in
  let result = Masc_domain.a2a_task_of_yojson json in
  check bool "roundtrip ok" true (is_ok result)

(* ============================================================ *)
(* Masc_domain.portal Tests                                            *)
(* ============================================================ *)

let test_portal_roundtrip () =
  let portal = Masc_domain.{
    portal_from = "claude";
    portal_target = "gemini";
    portal_opened_at = "2024-01-01T00:00:00Z";
    portal_status = PortalOpen;
    task_count = 5;
  } in
  let json = Masc_domain.portal_to_yojson portal in
  let result = Masc_domain.portal_of_yojson json in
  check bool "roundtrip ok" true (is_ok result)

(* ============================================================ *)
(* Masc_domain.tool_result Tests                                       *)
(* ============================================================ *)

let test_tool_result_success () =
  let result = Masc_domain.{
    success = true;
    message = "Operation completed";
    data = Some (`Assoc [("count", `Int 42)]);
  } in
  let json = Masc_domain.tool_result_to_yojson result in
  let open Yojson.Safe.Util in
  check bool "has success" true (json |> member "success" |> to_bool);
  check string "message" "Operation completed" (json |> member "message" |> to_string)

let test_tool_result_no_data () =
  let result = Masc_domain.{
    success = false;
    message = "Operation failed";
    data = None;
  } in
  let json = Masc_domain.tool_result_to_yojson result in
  let open Yojson.Safe.Util in
  check bool "success false" false (json |> member "success" |> to_bool)

(* ============================================================ *)
(* Masc_domain.agent_credential Tests                                  *)
(* ============================================================ *)

let test_agent_credential_roundtrip () =
  let cred = Masc_domain.{
    id = None;
    agent_id = None;
    agent_name = "claude-secure";
    token = "sha256:abc123";
    role = Admin;
    created_at = "2024-01-01T00:00:00Z";
    expires_at = Some "2024-02-01T00:00:00Z";
  } in
  let json = Masc_domain.agent_credential_to_yojson cred in
  let result = Masc_domain.agent_credential_of_yojson json in
  check bool "roundtrip ok" true (is_ok result)

let test_agent_credential_no_expiry () =
  let cred = Masc_domain.{
    id = None;
    agent_id = None;
    agent_name = "worker-1";
    token = "sha256:xyz789";
    role = Worker;
    created_at = "2024-01-01T00:00:00Z";
    expires_at = None;
  } in
  let json = Masc_domain.agent_credential_to_yojson cred in
  let result = Masc_domain.agent_credential_of_yojson json in
  check bool "roundtrip ok" true (is_ok result)

(* ============================================================ *)
(* Masc_domain.auth_config Tests                                       *)
(* ============================================================ *)

let test_default_auth_config () =
  let cfg = Masc_domain.default_auth_config in
  check bool "not enabled" false cfg.enabled;
  check int "token_expiry_hours" 24 cfg.token_expiry_hours

let test_auth_config_roundtrip () =
  let cfg = Masc_domain.{
    enabled = true;
    room_secret_hash = Some "sha256:secret";
    require_token = true;
    token_expiry_hours = 48;
  } in
  let json = Masc_domain.auth_config_to_yojson cfg in
  let result = Masc_domain.auth_config_of_yojson json in
  check bool "roundtrip ok" true (is_ok result)

(* ============================================================ *)
(* Coord_utils.parse_gitdir Tests                                 *)
(* ============================================================ *)

let test_parse_gitdir_worktree () =
  let line = "gitdir: /home/user/project/.git/worktrees/feature-branch" in
  let result = Coord_utils.parse_gitdir_to_main_root line in
  check bool "is Some" true (Option.is_some result)

let test_parse_gitdir_invalid () =
  let line = "not a gitdir line" in
  let result = Coord_utils.parse_gitdir_to_main_root line in
  check bool "is None" true (Option.is_none result)

(* ============================================================ *)
(* Coord_utils.sanitize Tests                                     *)
(* ============================================================ *)

let test_sanitize_html () =
  let input = "<script>alert('xss')</script>" in
  let result = Coord_utils.sanitize_html input in
  check bool "no angle brackets" true
    (not (String.contains result '<') && not (String.contains result '>'));
  check bool "escaped lt" true (String.length result > String.length input)

let test_sanitize_html_quotes () =
  let input = "Hello \"world\" & 'friends'" in
  let result = Coord_utils.sanitize_html input in
  check bool "quotes escaped" true
    (not (String.contains result '"') && not (String.contains result '\''))

let test_safe_filename () =
  let input = "file with spaces & special<chars>.txt" in
  let result = Coord_utils.safe_filename input in
  check bool "no spaces" false (String.contains result ' ');
  check bool "no ampersand" false (String.contains result '&');
  check bool "no angle" false (String.contains result '<')

let test_safe_filename_valid () =
  let input = "valid_file-name.txt" in
  let result = Coord_utils.safe_filename input in
  check string "unchanged" input result

(* ============================================================ *)
(* Coord_utils.validation Tests                                   *)
(* ============================================================ *)

let test_validate_agent_name_valid () =
  let result = Coord_utils.validate_agent_name "claude-123" in
  check bool "valid" true (is_ok result)

let test_validate_agent_name_r_valid () =
  let result = Coord_utils.validate_agent_name_r "valid-agent" in
  check bool "ok result" true (is_ok result)

let test_validate_task_id_valid () =
  let result = Coord_utils.validate_task_id "task-12345" in
  check bool "valid" true (is_ok result)

let test_validate_task_id_r_valid () =
  let result = Coord_utils.validate_task_id_r "task-abc" in
  check bool "ok result" true (is_ok result)

let test_validate_room_id_valid () =
  let room_id_result = Coord_utils.validate_room_id "room-alpha_01" in
  check (result string string) "valid room id" (Ok "room-alpha_01") room_id_result

let test_validate_room_id_trims_whitespace () =
  let room_id_result = Coord_utils.validate_room_id "  room-alpha_01  " in
  check (result string string) "trimmed room id" (Ok "room-alpha_01") room_id_result

let test_validate_room_id_rejects_path_traversal () =
  let result = Coord_utils.validate_room_id "../../tmp/x" in
  check bool "invalid traversal" true (is_error result)

let test_validate_room_id_rejects_invalid_chars () =
  let result = Coord_utils.validate_room_id "room id" in
  check bool "invalid chars" true (is_error result)

let test_validate_file_path_valid () =
  let result = Coord_utils.validate_file_path "src/main.ml" in
  check bool "valid" true (is_ok result)

let test_validate_file_path_too_long () =
  let long_path = String.make 501 'a' in
  let result = Coord_utils.validate_file_path long_path in
  check bool "invalid too long" true (is_error result)

let test_validate_file_path_angle_brackets () =
  let result = Coord_utils.validate_file_path "file<name>.txt" in
  check bool "invalid angle brackets" true (is_error result)

(* ============================================================ *)
(* Coord_utils.contains_substring Tests                           *)
(* ============================================================ *)

let test_contains_substring_true () =
  check bool "contains" true (Coord_utils.contains_substring "hello world" "world")

let test_contains_substring_false () =
  check bool "not contains" false (Coord_utils.contains_substring "hello world" "foo")

let test_contains_substring_empty () =
  check bool "empty needle" true (Coord_utils.contains_substring "hello" "")

(* ============================================================ *)
(* Coord_eio.event_type Tests                                     *)
(* ============================================================ *)

let test_room_eio_event_type_to_string () =
  check string "AgentJoin" "agent_join" (Coord_eio.event_type_to_string Coord_eio.AgentJoin);
  check string "AgentLeave" "agent_leave" (Coord_eio.event_type_to_string Coord_eio.AgentLeave);
  check string "Broadcast" "broadcast" (Coord_eio.event_type_to_string Coord_eio.Broadcast);
  check string "LockAcquire" "lock_acquire" (Coord_eio.event_type_to_string Coord_eio.LockAcquire);
  check string "LockRelease" "lock_release" (Coord_eio.event_type_to_string Coord_eio.LockRelease)

(* ============================================================ *)
(* Coord_eio.now_iso Tests                                        *)
(* ============================================================ *)

let test_room_eio_now_iso () =
  let ts = Coord_eio.now_iso () in
  check bool "contains T" true (String.contains ts 'T');
  check bool "ends with Z" true (ts.[String.length ts - 1] = 'Z');
  (* Has milliseconds: YYYY-MM-DDTHH:MM:SS.mmmZ *)
  check bool "has ms" true (String.contains ts '.')

(* ============================================================ *)
(* Coord_eio.room_state JSON Tests                                *)
(* ============================================================ *)

let test_room_eio_default_room_state () =
  let state = Coord_eio.default_room_state () in
  check string "protocol_version" "1.0.0" state.protocol_version;
  check bool "not paused" false state.paused;
  check (list string) "no active agents" [] state.active_agents

let test_room_eio_room_state_roundtrip () =
  let state = Coord_eio.{
    protocol_version = "1.0.0";
    started_at = 1704067200.0;
    last_updated = 1704070800.0;
    active_agents = ["claude"; "gemini"];
    message_seq = 42;
    event_seq = 10;
    mode = "collaborative";
    paused = true;
    paused_by = Some "admin";
    paused_at = Some 1704070000.0;
    pause_reason = Some "Maintenance";
  } in
  let json = Coord_eio.room_state_to_json state in
  let result = Coord_eio.room_state_of_json json in
  check bool "roundtrip ok" true (is_ok result)

(* ============================================================ *)
(* Coord_eio.agent_state JSON Tests                               *)
(* ============================================================ *)

let test_room_eio_agent_state_roundtrip () =
  let agent = Coord_eio.{
    name = "test-agent";
    last_seen = 1704067200.0;
    capabilities = ["code"; "review"; "test"];
    status = "active";
  } in
  let json = Coord_eio.agent_state_to_json agent in
  let result = Coord_eio.agent_state_of_json json in
  check bool "roundtrip ok" true (is_ok result)

(* ============================================================ *)
(* Coord_eio.lock_info JSON Tests                                 *)
(* ============================================================ *)

let test_room_eio_lock_info_roundtrip () =
  let lock = Coord_eio.{
    resource = "src/main.ml";
    owner = "claude";
    acquired_at = 1704067200.0;
    expires_at = 1704070800.0;
  } in
  let json = Coord_eio.lock_info_to_json lock in
  let result = Coord_eio.lock_info_of_json json in
  check bool "roundtrip ok" true (is_ok result)

let test_room_eio_lock_info_int_floats () =
  (* Test parsing when floats are encoded as ints *)
  let json = `Assoc [
    ("resource", `String "file.ml");
    ("owner", `String "agent");
    ("acquired_at", `Int 1704067200);
    ("expires_at", `Intlit "1704070800");
  ] in
  let result = Coord_eio.lock_info_of_json json in
  check bool "parses int as float" true (is_ok result)

(* ============================================================ *)
(* Coord_eio.message JSON Tests                                   *)
(* ============================================================ *)

let test_room_eio_message_roundtrip () =
  let msg = Coord_eio.{
    seq = 42;
    from_agent = "claude";
    content = "Hello @gemini, please review this";
    mention = Some "gemini";
    timestamp = 1704067200.0;
  } in
  let json = Coord_eio.message_to_json msg in
  let result = Coord_eio.message_of_json json in
  check bool "roundtrip ok" true (is_ok result)

let test_room_eio_message_no_mention () =
  let msg = Coord_eio.{
    seq = 1;
    from_agent = "gemini";
    content = "General broadcast";
    mention = None;
    timestamp = 1704067200.0;
  } in
  let json = Coord_eio.message_to_json msg in
  let result = Coord_eio.message_of_json json in
  check bool "roundtrip ok" true (is_ok result)

(* ============================================================ *)
(* Test Suite                                                    *)
(* ============================================================ *)

let agent_id_tests = [
  "of_string/to_string", `Quick, test_agent_id_of_string;
  "equal", `Quick, test_agent_id_equal;
  "to_yojson", `Quick, test_agent_id_to_yojson;
  "of_yojson valid", `Quick, test_agent_id_of_yojson_valid;
  "of_yojson invalid", `Quick, test_agent_id_of_yojson_invalid;
]

let task_id_tests = [
  "of_string/to_string", `Quick, test_task_id_of_string;
  "equal", `Quick, test_task_id_equal;
  "generate unique", `Quick, test_task_id_generate;
  "to_yojson", `Quick, test_task_id_to_yojson;
  "of_yojson valid", `Quick, test_task_id_of_yojson_valid;
  "of_yojson invalid", `Quick, test_task_id_of_yojson_invalid;
]

let timestamp_tests = [
  "now_iso format", `Quick, test_now_iso_format;
  "parse_iso8601 valid", `Quick, test_parse_iso8601_valid;
  "parse_iso8601 invalid", `Quick, test_parse_iso8601_invalid;
]

let agent_status_tests = [
  "to_string all", `Quick, test_agent_status_to_string;
  "of_string_opt", `Quick, test_agent_status_of_string_opt;
  "of_string_r (#10748)", `Quick, test_agent_status_of_string_r;
  "to_yojson", `Quick, test_agent_status_to_yojson;
  "of_yojson valid", `Quick, test_agent_status_of_yojson_valid;
  "of_yojson invalid", `Quick, test_agent_status_of_yojson_invalid;
]

let task_status_tests = [
  "Todo roundtrip", `Quick, test_task_status_todo;
  "Claimed roundtrip", `Quick, test_task_status_claimed;
  "InProgress roundtrip", `Quick, test_task_status_in_progress;
  "Done roundtrip", `Quick, test_task_status_done;
  "Done no notes", `Quick, test_task_status_done_no_notes;
  "Cancelled roundtrip", `Quick, test_task_status_cancelled;
  "unknown status error", `Quick, test_task_status_of_yojson_unknown;
]

let tempo_tests = [
  "mode to_string", `Quick, test_tempo_mode_to_string;
  "mode of_string", `Quick, test_tempo_mode_of_string;
  "mode roundtrip", `Quick, test_tempo_mode_roundtrip;
  "default config", `Quick, test_default_tempo_config;
  "config roundtrip", `Quick, test_tempo_config_roundtrip;
]

let a2a_tests = [
  "status all", `Quick, test_a2a_task_status_all;
  "status unknown error", `Quick, test_a2a_task_status_of_string_unknown;
  "task roundtrip", `Quick, test_a2a_task_roundtrip;
  "task with result", `Quick, test_a2a_task_with_result;
]

let portal_tests = [
  "state all", `Quick, test_portal_state_all;
  "state unknown error", `Quick, test_portal_state_of_string_unknown;
  "roundtrip", `Quick, test_portal_roundtrip;
]

let role_tests = [
  "all roles", `Quick, test_agent_role_all;
  "unknown error", `Quick, test_agent_role_of_string_unknown;
  "permissions worker", `Quick, test_permissions_worker;
  "permissions admin", `Quick, test_permissions_admin;
  "has_permission", `Quick, test_has_permission;
]

let rate_limit_tests = [
  "default config", `Quick, test_default_rate_limit;
  "limit_for_category", `Quick, test_limit_for_category;
  "category_for_tool", `Quick, test_category_for_tool;
  "multiplier_for_role", `Quick, test_multiplier_for_role;
  "effective_limit", `Quick, test_effective_limit;
  "config roundtrip", `Quick, test_rate_limit_config_roundtrip;
]

let error_tests = [
  "masc_error to_string", `Quick, test_masc_error_to_string;
]

let worktree_tests = [
  "roundtrip", `Quick, test_worktree_info_roundtrip;
]

let task_tests = [
  "roundtrip", `Quick, test_task_roundtrip;
  "with worktree", `Quick, test_task_with_worktree;
]

let backlog_tests = [
  "roundtrip", `Quick, test_backlog_roundtrip;
]

let tool_result_tests = [
  "success", `Quick, test_tool_result_success;
  "no data", `Quick, test_tool_result_no_data;
]

let credential_tests = [
  "roundtrip", `Quick, test_agent_credential_roundtrip;
  "no expiry", `Quick, test_agent_credential_no_expiry;
]

let auth_config_tests = [
  "default", `Quick, test_default_auth_config;
  "roundtrip", `Quick, test_auth_config_roundtrip;
]

let gitdir_tests = [
  "parse worktree", `Quick, test_parse_gitdir_worktree;
  "parse invalid", `Quick, test_parse_gitdir_invalid;
]

let sanitize_tests = [
  "html script", `Quick, test_sanitize_html;
  "html quotes", `Quick, test_sanitize_html_quotes;
  "safe_filename special", `Quick, test_safe_filename;
  "safe_filename valid", `Quick, test_safe_filename_valid;
]

let validation_tests = [
  "agent_name valid", `Quick, test_validate_agent_name_valid;
  "agent_name_r valid", `Quick, test_validate_agent_name_r_valid;
  "task_id valid", `Quick, test_validate_task_id_valid;
  "task_id_r valid", `Quick, test_validate_task_id_r_valid;
  "room_id valid", `Quick, test_validate_room_id_valid;
  "room_id trims whitespace", `Quick, test_validate_room_id_trims_whitespace;
  "room_id rejects traversal", `Quick, test_validate_room_id_rejects_path_traversal;
  "room_id rejects invalid chars", `Quick, test_validate_room_id_rejects_invalid_chars;
  "file_path valid", `Quick, test_validate_file_path_valid;
  "file_path too long", `Quick, test_validate_file_path_too_long;
  "file_path angle brackets", `Quick, test_validate_file_path_angle_brackets;
]

let substring_tests = [
  "contains true", `Quick, test_contains_substring_true;
  "contains false", `Quick, test_contains_substring_false;
  "empty needle", `Quick, test_contains_substring_empty;
]

let room_eio_event_tests = [
  "event_type_to_string", `Quick, test_room_eio_event_type_to_string;
]

let room_eio_time_tests = [
  "now_iso", `Quick, test_room_eio_now_iso;
]

let room_eio_state_tests = [
  "default_room_state", `Quick, test_room_eio_default_room_state;
  "room_state roundtrip", `Quick, test_room_eio_room_state_roundtrip;
]

let room_eio_agent_tests = [
  "agent_state roundtrip", `Quick, test_room_eio_agent_state_roundtrip;
]

let room_eio_lock_tests = [
  "lock_info roundtrip", `Quick, test_room_eio_lock_info_roundtrip;
  "lock_info int floats", `Quick, test_room_eio_lock_info_int_floats;
]

let room_eio_message_tests = [
  "message roundtrip", `Quick, test_room_eio_message_roundtrip;
  "message no mention", `Quick, test_room_eio_message_no_mention;
]

let () =
  run "Types & Utils Coverage" [
    "Agent_id", agent_id_tests;
    "Task_id", task_id_tests;
    "Timestamp", timestamp_tests;
    "agent_status", agent_status_tests;
    "task_status", task_status_tests;
    "tempo", tempo_tests;
    "a2a", a2a_tests;
    "portal", portal_tests;
    "agent_role", role_tests;
    "rate_limit", rate_limit_tests;
    "masc_error", error_tests;
    "worktree_info", worktree_tests;
    "task", task_tests;
    "backlog", backlog_tests;
    "tool_result", tool_result_tests;
    "agent_credential", credential_tests;
    "auth_config", auth_config_tests;
    "gitdir_parse", gitdir_tests;
    "sanitize", sanitize_tests;
    "validation", validation_tests;
    "contains_substring", substring_tests;
    "Coord_eio.event", room_eio_event_tests;
    "Coord_eio.time", room_eio_time_tests;
    "Coord_eio.state", room_eio_state_tests;
    "Coord_eio.agent", room_eio_agent_tests;
    "Coord_eio.lock", room_eio_lock_tests;
    "Coord_eio.message", room_eio_message_tests;
  ]
