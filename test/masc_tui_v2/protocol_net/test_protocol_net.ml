open Masc_tui_core
open Masc_tui_protocol
open Masc_tui_net

let t0 = Clock.Mono.of_ns 1_000_000_000L

let parse_json s = Yojson.Safe.from_string s

let expect_ok label = function
  | Ok v -> v
  | Error msg -> Alcotest.failf "%s: expected Ok, got Error %S" label msg

let expect_err label = function
  | Error msg -> msg
  | Ok _ -> Alcotest.failf "%s: expected Error, got Ok" label

let assoc_keys = function
  | `Assoc fields -> List.sort String.compare (List.map fst fields)
  | _ -> Alcotest.fail "expected JSON object"

let json_field key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some v -> v
      | None -> Alcotest.failf "missing JSON key %S" key)
  | _ -> Alcotest.failf "expected JSON object for key %S" key

(* 1. Wire_common: envelopes, Observed.t, RFC3339, public & full /health, api_error *)
let test_wire_common () =
  let env_json =
    parse_json
      {|{
        "schema_version": 1,
        "instance_id": "srv-abc123",
        "generated_at_unix": 1795252092.5,
        "data": { "x": 42, "y": null }
      }|}
  in
  let meta, data = expect_ok "envelope" (Wire_common.unwrap_v2_envelope env_json) in
  Alcotest.(check int) "schema_version" 1 meta.schema_version;
  Alcotest.(check string) "instance_id" "srv-abc123" meta.instance_id;
  let ox = expect_ok "obs x" (Wire_common.observed_int ~observed_at:t0 data "x") in
  let oy = expect_ok "obs y" (Wire_common.observed_int ~observed_at:t0 data "y") in
  let oz = expect_ok "obs z" (Wire_common.observed_int ~observed_at:t0 data "z") in
  Alcotest.(check bool) "present -> Value" true (Observed.is_value ox);
  Alcotest.(check bool) "null -> Absent" true (Observed.equal Int.equal oy Observed.absent);
  Alcotest.(check bool) "missing -> Unreported" true (Observed.equal Int.equal oz Observed.unreported);
  (* RFC3339 roundtrip *)
  let ts = expect_ok "rfc3339" (Wire_common.parse_rfc3339_unix "2026-11-21T18:04:28Z") in
  Alcotest.(check string) "rfc3339 format" "2026-11-21T18:04:28Z"
    (Wire_common.format_unix_rfc3339 ts);
  let ts_tz = expect_ok "rfc3339 +09:00" (Wire_common.parse_rfc3339_unix "2026-11-22T03:04:28+09:00") in
  Alcotest.(check (float 0.001)) "tz matches UTC" ts ts_tz;
  (* Public unauthenticated /health — NO paths, NO fabricated workspace identity *)
  let public_health_json =
    parse_json
      {|{
        "server": "masc",
        "version": "0.78.0",
        "live": true,
        "ready": true,
        "phase": "ready"
      }|}
  in
  let ph = expect_ok "public health" (Wire_common.decode_server_health public_health_json) in
  Alcotest.(check string) "public version" "0.78.0" ph.version;
  Alcotest.(check bool) "public ok" true ph.ok;
  (match ph.scope with
  | Wire_common.Public_health -> ()
  | Wire_common.Full_health _ -> Alcotest.fail "expected Public_health");
  (* Authenticated full /health with real paths.effective_base_path & string uptime *)
  let full_health_json =
    parse_json
      {|{
        "server": "masc",
        "version": "0.78.0",
        "release_version": "0.78.0",
        "build": { "release_version": "0.78.0", "git_commit": "b8a5dbeb", "runtime_instance_id": "srv-84bc6b04" },
        "health_detail": "full",
        "paths": {
          "effective_base_path": "/srv/masc",
          "effective_masc_root": "/srv/masc/.masc",
          "workspace_sha256": "deadbeef"
        },
        "uptime": "1h 12m 4s",
        "startup": { "phase": "ready", "live": true, "ready": true },
        "gc": { "live_words": 1000, "heap_words": 4000, "major_collections": 5, "minor_collections": 50 }
      }|}
  in
  let fh = expect_ok "full health" (Wire_common.decode_server_health full_health_json) in
  Alcotest.(check (option string)) "uptime_display" (Some "1h 12m 4s") fh.uptime_display;
  (match fh.scope with
  | Wire_common.Full_health id ->
      Alcotest.(check string) "base_path" "/srv/masc" id.base_path;
      Alcotest.(check string) "masc_root" "/srv/masc/.masc" id.masc_root;
      Alcotest.(check (option string)) "instance_id" (Some "srv-84bc6b04") id.instance_id
  | Wire_common.Public_health -> Alcotest.fail "expected Full_health");
  (* Reject full /health that omits effective_masc_root rather than fabricating *)
  let missing_root =
    parse_json {|{ "version": "0.78.0", "paths": { "effective_base_path": "/srv/masc" } }|}
  in
  ignore (expect_err "reject missing masc_root" (Wire_common.decode_server_health missing_root) : string);
  (* Reject multi-account server *)
  let bad_health =
    parse_json {|{ "account_mode": "multi", "version": "0.78.0", "live": true }|}
  in
  ignore (expect_err "reject account_mode" (Wire_common.decode_server_health bad_health) : string);
  (* api_error with observed_workspace_sha256 *)
  let err_json =
    parse_json
      {|{
        "error": "workspace_mismatch",
        "code": "workspace_mismatch",
        "message": "workspace changed",
        "expected_instance": "srv-a",
        "observed_instance": "srv-b",
        "observed_workspace_sha256": "sha256-xyz"
      }|}
  in
  let api_err = expect_ok "api error" (Wire_common.decode_api_error err_json) in
  Alcotest.(check (option string)) "observed_workspace_sha256"
    (Some "sha256-xyz") api_err.observed_workspace_sha256

(* 2. Wire_fleet: real /api/v1/dashboard/shell, Fleet_stream, turns, chat allowlist & history *)
let test_wire_fleet () =
  let shell_json =
    parse_json
      {|{
        "generated_at": "2026-11-21T18:04:28Z",
        "status": { "project": "masc-mcp", "version": "0.78.0" },
        "counts": {
          "agents": 2,
          "tasks": 18,
          "tasks_done_24h": 14,
          "keepers": 4,
          "persisted_keepers": 4,
          "total_runtimes": 6
        },
        "configured_keepers": 5,
        "scorecard_24h": {
          "tasks_done_24h": 14,
          "tasks_done_total": 120,
          "tasks_in_progress": 3,
          "tasks_claimed": 1,
          "tasks_awaiting_verification": 2,
          "tasks_todo": 5,
          "tasks_cancelled": 0
        },
        "groups": [
          { "group": "review", "keeper_count": 2, "keepers": ["review-alpha", "review-beta"] },
          { "group": "wkbl", "keeper_count": 1, "keepers": ["wkbl-growth"] }
        ]
      }|}
  in
  let shell = expect_ok "dashboard shell" (Wire_fleet.decode_dashboard_shell ~observed_at:t0 shell_json) in
  Alcotest.(check int) "shell counts.keepers" 4 shell.counts.keepers;
  Alcotest.(check (option int)) "scorecard tasks_done_24h" (Some 14)
    (Observed.to_option shell.scorecard_24h.tasks_done_24h);
  Alcotest.(check int) "shell groups" 2 (List.length shell.groups);
  (* Roster + company grouping *)
  let roster_json =
    parse_json
      {|{
        "keepers": [
          { "name": "wkbl-growth", "group": "wkbl-startup", "health": "working", "paused": false, "keepalive_running": true, "activation_mode": "autonomous", "runtime_id": "codex-pro" },
          { "name": "review-alpha", "health": "healthy", "paused": false, "keepalive_running": true, "activation_mode": "on_demand", "runtime_id": "claude-max" },
          { "name": "review-beta", "health": "paused", "paused": true, "keepalive_running": false, "activation_mode": "manual", "runtime_id": "claude-max" },
          { "name": "solo-scout", "health": "idle", "paused": false, "keepalive_running": true, "activation_mode": "autonomous", "runtime_id": "ollama-local" }
        ]
      }|}
  in
  let keepers =
    (expect_ok "roster" (Wire_fleet.decode_keepers_roster ~observed_at:t0 roster_json))
      .keepers
  in
  let companies = Wire_fleet.group_by_company keepers in
  Alcotest.(check (list string)) "company grouping"
    [ "review"; "wkbl-startup"; "Other" ]
    (List.map (fun (c : Wire_fleet.company_group) -> c.company) companies);
  (* Real Fleet_stream events: snapshot, changed, unavailable_snapshot, degraded *)
  let fleet_snap =
    expect_ok "fleet snapshot"
      (Wire_fleet.decode_fleet_stream_event
         (parse_json
            {|{
              "event": "snapshot",
              "schema": 1,
              "revision": 3,
              "measured_at": 1795252090.0,
              "fleet": {
                "status": "ok",
                "operator_action_required": false,
                "bootable_count": 4,
                "running_count": 3,
                "executable_count": 3,
                "failing_count": 0,
                "recovering_count": 0,
                "paused_count": 1,
                "proactive_interval_sec": 300
              },
              "degraded": null
            }|}))
  in
  (match fleet_snap with
  | Wire_fleet.Fleet_snapshot { revision = 3; degraded = None; _ } -> ()
  | Wire_fleet.Fleet_snapshot _ | Wire_fleet.Fleet_changed _
  | Wire_fleet.Fleet_unavailable_snapshot _ | Wire_fleet.Fleet_degraded _ ->
      Alcotest.fail "expected Fleet_snapshot");
  let fleet_unavail =
    expect_ok "fleet unavailable_snapshot"
      (Wire_fleet.decode_fleet_stream_event
         (parse_json
            {|{
              "event": "unavailable_snapshot",
              "schema": 1,
              "revision": 4,
              "since": 1795252095.0,
              "reason": "store_unreadable"
            }|}))
  in
  (match fleet_unavail with
  | Wire_fleet.Fleet_unavailable_snapshot
      { revision = 4; degradation = { reason = "store_unreadable"; _ }; _ } ->
      ()
  | Wire_fleet.Fleet_snapshot _ | Wire_fleet.Fleet_changed _
  | Wire_fleet.Fleet_unavailable_snapshot _ | Wire_fleet.Fleet_degraded _ ->
      Alcotest.fail "expected Fleet_unavailable_snapshot");
  (* /api/v1/keepers/turns with real chat_operation and maintenance lanes *)
  let turns_json =
    parse_json
      {|{
        "keepers": [
          {
            "keeper_name": "k1",
            "status": "ok",
            "turn": { "lane": "chat_operation", "started_at_unix": 1795252000.0, "interrupt_token": "itok-1" }
          },
          {
            "keeper_name": "k2",
            "status": "ok",
            "turn": { "lane": "maintenance", "started_at_unix": 1795252010.0, "interrupt_token": "itok-2" }
          }
        ]
      }|}
  in
  let turns = expect_ok "keeper turns" (Wire_fleet.decode_keeper_turns turns_json) in
  Alcotest.(check int) "2 turn rows" 2 (List.length turns);
  (* /api/v1/keepers/turns with live server turn.preview & turn_ref *)
  let turns_with_preview_json =
    parse_json
      {|{
        "keepers": [
          {
            "keeper_name": "e-masc-the-leader",
            "chat_control_token": "ctrl-9",
            "status": "ok",
            "turn": {
              "lane": "autonomous",
              "turn_ref": "trace-1#15206",
              "started_at_unix": 1795503055.0,
              "interrupt_token": "itok-auto-1",
              "preview": {
                "status_text": "ollama · waiting for provider response · last observed tool: Execute",
                "activity": "waiting",
                "text_tail": "Checking test fixtures\nnext line",
                "text_position": { "generation": 2, "start_byte": 0 },
                "last_tool": "Execute",
                "updated_at_unix": 1795503086.0,
                "preparation": {
                  "phase": "prompt",
                  "turn_ref": "trace-1#15206",
                  "started_at_unix": 1795503056.0,
                  "state": "active",
                  "finished_at_unix": null,
                  "elapsed_ns": null
                },
                "preparation_timeline": null,
                "execution_scope": null
              }
            }
          }
        ]
      }|}
  in
  (match
     expect_ok "keeper turns with preview"
       (Wire_fleet.decode_keeper_turns turns_with_preview_json)
   with
  | [
      {
        keeper_name = "e-masc-the-leader";
        chat_control_token = Some "ctrl-9";
        state = Wire_fleet.Turn_active turn;
      };
    ] -> (
      Alcotest.(check bool) "autonomous lane decoded" true
        (Wire_fleet.equal_turn_lane turn.lane Wire_fleet.Lane_proactive);
      Alcotest.(check (option string)) "turn_ref decoded" (Some "trace-1#15206")
        turn.turn_ref;
      match turn.preview with
      | Some prev -> (
          Alcotest.(check bool) "preview activity decoded" true
            (Wire_fleet.equal_turn_preview_activity prev.activity
               Wire_fleet.Preview_waiting);
          Alcotest.(check (option string)) "preview last_tool decoded"
            (Some "Execute") prev.last_tool;
          Alcotest.(check string) "preview text_tail decoded"
            "Checking test fixtures\nnext line" prev.text_tail;
          match prev.preparation with
          | Some prep ->
              Alcotest.(check bool) "preparation phase decoded" true
                (Wire_fleet.equal_turn_preparation_phase prep.phase
                   Wire_fleet.Prep_prompt);
              Alcotest.(check bool) "preparation state decoded" true
                (Wire_fleet.equal_turn_preparation_state prep.state
                   Wire_fleet.Prep_active)
          | None -> Alcotest.fail "expected decoded preview preparation")
      | None -> Alcotest.fail "expected decoded turn.preview")
  | _ -> Alcotest.fail "expected single active turn row with preview");
  (* Strict rejection of unknown preview activity / preparation enums *)
  let bad_activity_json =
    parse_json
      {|{
        "keepers": [
          {
            "keeper_name": "k-bad",
            "status": "ok",
            "turn": {
              "lane": "autonomous",
              "started_at_unix": 1795503055.0,
              "interrupt_token": "itok-bad",
              "preview": {
                "status_text": "bad",
                "activity": "invented_activity",
                "text_tail": "",
                "last_tool": null,
                "updated_at_unix": 1795503086.0,
                "preparation": null
              }
            }
          }
        ]
      }|}
  in
  Alcotest.(check bool) "unknown preview activity fails decode" true
    (Result.is_error (Wire_fleet.decode_keeper_turns bad_activity_json));
  let bad_prep_json =
    parse_json
      {|{
        "keepers": [
          {
            "keeper_name": "k-bad-prep",
            "status": "ok",
            "turn": {
              "lane": "autonomous",
              "started_at_unix": 1795503055.0,
              "interrupt_token": "itok-bad-prep",
              "preview": {
                "status_text": "bad",
                "activity": "preparing",
                "text_tail": "",
                "last_tool": null,
                "updated_at_unix": 1795503086.0,
                "preparation": {
                  "phase": "unknown_phase",
                  "state": "active",
                  "started_at_unix": 1795503056.0
                }
              }
            }
          }
        ]
      }|}
  in
  Alcotest.(check bool) "unknown preparation phase fails decode" true
    (Result.is_error (Wire_fleet.decode_keeper_turns bad_prep_json));
  (* Strict allowlist on POST /api/v1/keepers/chat/stream *)
  let steer_json =
    Wire_fleet.encode_chat_submit_request
      {
        request_id = "op-123";
        keeper_name = "wkbl-growth";
        message = "Focus on Q4 launch";
        origin = Wire_fleet.Origin_bare;
        mode =
          Wire_fleet.Steer
            { control_token = "ctrl-42"; operation_id = "op-122" };
        turn_instructions = None;
        since_seq = None;
        attachments = [];
      }
  in
  Alcotest.(check (list string)) "steer exact allowlisted keys"
    [ "admission_intent"; "message"; "name"; "request_id" ]
    (assoc_keys steer_json);
  let ai = json_field "admission_intent" steer_json in
  Alcotest.(check (list string)) "admission_intent exact 4 keys"
    [ "control_token"; "interrupt_token"; "kind"; "operation_id" ]
    (assoc_keys ai);
  Alcotest.(check bool) "steer names its own operation, never a turn token"
    true
    (json_field "operation_id" ai = `String "op-122"
    && json_field "interrupt_token" ai = `Null);
  let followup_json =
    Wire_fleet.encode_chat_submit_request
      {
        request_id = "op-124";
        keeper_name = "wkbl-growth";
        message = "Queue me";
        origin = Wire_fleet.Origin_bare;
        mode = Wire_fleet.Follow_up;
        turn_instructions = None;
        since_seq = None;
        attachments = [];
      }
  in
  Alcotest.(check (list string)) "follow_up omits admission_intent"
    [ "message"; "name"; "request_id" ]
    (assoc_keys followup_json);
  (* Bare JSON array /chat/history + paginated /chat/history/page *)
  let hist =
    expect_ok "bare chat history"
      (Wire_fleet.decode_chat_history
         (parse_json
            {|[{"id":"m-1","role":"user","content":"hi","ts":1795252000.0}]|}))
  in
  Alcotest.(check int) "1 chat msg" 1 (List.length hist);
  let page =
    expect_ok "chat history page"
      (Wire_fleet.decode_chat_history_page
         (parse_json
            {|{
              "schema": "masc.keeper_chat_history.page.v2",
              "messages": [{"id":"m-1","role":"assistant","content":"hello","ts":1795252001.0}],
              "has_more": true,
              "next_cursor": "cur-99"
            }|}))
  in
  Alcotest.(check bool) "page has_more" true page.has_more;
  Alcotest.(check (option string)) "page next_cursor" (Some "cur-99") page.next_cursor

(* 3. Wire_work: Goal phase, Task strict priority, Verification, Schedules, Asks, Approvals, 15 Candle events *)
let test_wire_work () =
  let valid_goal =
    parse_json
      {|{
        "id": "goal-1",
        "title": "Ship MASC TUI v2",
        "phase": "paused",
        "resume_phase": "verifying",
        "priority": 1,
        "measure": "All 6 workspaces pass visual gate",
        "procedure": "Run capture_tui.py",
        "criterion_revision": "rev-3",
        "criterion_review": { "status": "valid" },
        "linked_task_count": 6
      }|}
  in
  let g = expect_ok "valid goal" (Wire_work.decode_goal ~observed_at:t0 valid_goal) in
  Alcotest.(check bool) "paused resume verifying" true
    (g.phase = Wire_work.Paused Wire_work.Resume_verifying);
  (* Legacy 'status' MUST be rejected *)
  let legacy_goal =
    parse_json
      {|{ "id": "g-bad", "title": "Bad", "status": "active", "phase": "executing", "priority": 1, "measure": "m", "procedure": "p" }|}
  in
  ignore (expect_err "reject legacy status" (Wire_work.decode_goal ~observed_at:t0 legacy_goal) : string);
  (* POST /api/v1/goals/confirmation exact 7-key allowlist *)
  let confirm_json =
    Wire_work.encode_goal_confirmation
      {
        goal_id = "goal-1";
        criterion_revision = "rev-3";
        request_id = "req-1";
        verification_run_id = "vrun-1";
        expected_workspace = { base_path = "/srv/masc"; masc_root = "/srv/masc/.masc" };
        expected_operator_id = "dancer";
        expected_runtime_instance_id = "srv-84bc6b04";
      }
  in
  Alcotest.(check (list string)) "goal confirmation exact allowlist"
    [
      "criterion_revision"; "expected_operator_id";
      "expected_runtime_instance_id"; "expected_workspace";
      "goal_id"; "request_id"; "verification_run_id";
    ]
    (assoc_keys confirm_json);
  (* Task missing priority MUST fail (zero silent default) *)
  ignore
    (expect_err "reject task missing priority"
       (Wire_work.decode_task (parse_json {|{ "id": "t-1", "title": "No prio", "task_status": "todo" }|}))
      : string);
  let task_linked =
    expect_ok "linked task"
      (Wire_work.decode_task
         (parse_json
            {|{
              "id": "task-10", "title": "Verify", "priority": 2, "goal_id": "goal-1",
              "task_status": { "kind": "awaiting_verification", "assignee": "m2", "started_at": "2026-11-21T18:00:00Z", "submitted_at": "2026-11-21T18:30:00Z", "verification_id": "ver-99" }
            }|}))
  in
  ignore (expect_err "already linked refused" (Wire_work.check_goal_link_assignable task_linked) : string);
  (* Verification requests with review_observation + strict verdict allowlist *)
  let ver_reqs =
    expect_ok "verification requests"
      (Wire_work.decode_verification_snapshot
         (parse_json
            {|{
              "requests": [
                {
                  "request_id": "ver-99",
                  "task_id": "task-10",
                  "task_title": "Verify codecs",
                  "submitted_by": "m2",
                  "created_at": "2026-11-21T18:30:00Z",
                  "completion_contract": ["build green"],
                  "required_artifacts": [],
                  "submitted_evidence": ["test.log"],
                  "evidence_projection_error": null,
                  "review_observation": { "state": "running", "detail": "", "actor": "verifier-2" }
                }
              ]
            }|}))
  in
  Alcotest.(check int) "1 verification req" 1 (List.length ver_reqs);
  let verdict_json =
    Wire_work.encode_verification_verdict ~task_id:"task-10"
      ~verification_id:"ver-99"
      ~verdict:(Wire_work.Verdict_reject { reason = "missing test" })
      ~notes:(Some "please add")
  in
  Alcotest.(check (list string)) "verdict allowlist"
    [ "notes"; "reason"; "task_id"; "verdict"; "verification_id" ]
    (assoc_keys verdict_json);
  Alcotest.(check string) "verdict reject" "reject"
    (expect_ok "verdict" (Wire_common.required_nonblank_string verdict_json "verdict"));
  (* Schedules with real "requests" array *)
  let scheds, next_cur =
    expect_ok "schedules"
      (Wire_work.decode_schedules_snapshot
         (parse_json
            {|{
              "status": "ok",
              "next_cursor": "cur-2",
              "requests": [
                {
                  "schedule_instance_id": "si-1",
                  "schedule_id": "sched-daily",
                  "status": "scheduled",
                  "source": "operator",
                  "due_at": 1795260000.0,
                  "next_due_at": 1795260000.0,
                  "recurrence_kind": "cron",
                  "recurrence_summary": "0 9 * * *",
                  "payload_kind": "keeper_wake",
                  "payload_support": "supported",
                  "payload_target": "wkbl-growth",
                  "payload_keeper_name": "wkbl-growth",
                  "payload_summary": "Daily standup",
                  "last_wake": { "status": "succeeded", "started_at": 1795173600.0, "finished_at": 1795173605.0 }
                }
              ]
            }|}))
  in
  Alcotest.(check int) "1 schedule" 1 (List.length scheds);
  Alcotest.(check (option string)) "next cursor" (Some "cur-2") next_cur;
  (* Server_dashboard_schedule_projection answers an unreadable store with
     200 and an empty list; that is a failed read, not "no schedules". *)
  Alcotest.(check string) "unreadable schedule store is an error"
    "schedule store read failed: lock timeout"
    (expect_err "schedule store unknown"
       (Wire_work.decode_schedules_snapshot
          (parse_json
             {|{ "status": "unknown", "schedule_store_known": false,
                 "schedule_store_read_error": "schedule store read failed: lock timeout",
                 "next_cursor": null, "requests": [] }|})));
  (* Dashboard_verification answers an unreadable backlog the same way. *)
  ignore
    (expect_err "verification backlog unreadable"
       (Wire_work.decode_verification_snapshot
          (parse_json
             {|{ "requests": [], "backlog_error": "backlog file corrupt",
                 "backlog_recovery": null, "awaiting_unresolved_total": 0,
                 "awaiting_unresolved": [] }|}))
      : string);
  (* Ask answer uses "name" and tagged response *)
  let ask_ans =
    Wire_work.encode_ask_answer ~keeper:"wkbl-growth" ~ask_id:"ask-1"
      ~answers:[ ("q1", Wire_work.Ask_chose [ "c1" ]); ("q2", Wire_work.Ask_wrote "yes") ]
      ()
  in
  Alcotest.(check string) "ask answer name" "wkbl-growth"
    (expect_ok "name" (Wire_common.required_nonblank_string ask_ans "name"));
  (* Tool approvals GET uses "pending", POST uses name + tool_call_id + approval_id + decision *)
  let approvals =
    expect_ok "tool approvals"
      (Wire_work.decode_tool_approvals
         (parse_json
            {|{
              "pending": [
                { "keeper": "k1", "tool_call_id": "tc-1", "approval_id": "ap-1", "tool": "bash", "args": "{}", "question": "ok?", "because": "shell", "asked_at": 1795252000.0, "timeout_sec": 60.0 }
              ]
            }|}))
  in
  Alcotest.(check int) "1 pending approval" 1 (List.length approvals);
  let ap_dec =
    Wire_work.encode_tool_approval_decision ~keeper:"k1" ~tool_call_id:"tc-1"
      ~approval_id:"ap-1" ~decision:Wire_work.Tool_deny ()
  in
  Alcotest.(check string) "decision deny" "deny"
    (expect_ok "decision" (Wire_common.required_nonblank_string ap_dec "decision"));
  (* The tool-approval answer, with the fields the route writes in
     server_routes_http_keeper_control.ml. *)
  let approval_answer ~settled ~remembered =
    Wire_work.decode_tool_approval_outcome
      (`Assoc
        [
          ("settled", `Bool settled);
          ("remembered", `Bool remembered);
          ("decision", `String "approve");
          ("actor", `String "operator");
        ])
  in
  Alcotest.(check bool) "settled answer" true
    (match
       expect_ok "settled" (approval_answer ~settled:true ~remembered:false)
     with
    | Wire_work.Tool_approval_settled -> true
    | Wire_work.Tool_approval_remembered | Wire_work.Tool_approval_no_waiting_call
      ->
        false);
  Alcotest.(check bool) "remembered answer" true
    (match
       expect_ok "remembered" (approval_answer ~settled:false ~remembered:true)
     with
    | Wire_work.Tool_approval_remembered -> true
    | Wire_work.Tool_approval_settled | Wire_work.Tool_approval_no_waiting_call
      ->
        false);
  Alcotest.(check bool) "answer no call took" true
    (match
       expect_ok "no waiting call"
         (approval_answer ~settled:false ~remembered:false)
     with
    | Wire_work.Tool_approval_no_waiting_call -> true
    | Wire_work.Tool_approval_settled | Wire_work.Tool_approval_remembered ->
        false);
  ignore
    (expect_err "settled and remembered"
       (approval_answer ~settled:true ~remembered:true));
  (* Real Candle Ledger: ledger_state=missing, nullable half_life_sec, all 15 event kinds *)
  let candle_json =
    parse_json
      {|{
        "schema_version": 1,
        "instance_id": "srv-1",
        "generated_at_unix": 1795252092.48,
        "data": {
          "ledger_state": "missing",
          "total_events": 15,
          "balance_error": null,
          "policy": { "configuration": "active", "disabled_reason": null, "pricing_mode": "linear", "half_life": { "mode": "off", "half_life_hours": null, "half_life_sec": null }, "half_life_sec": null },
          "supply": { "issued_milli": "1000", "burned_milli": "200", "circulating_milli": "800", "total_supply_milli": "800", "active_keepers": 1 },
          "diagnostics": { "unattributed_count": 1, "backlog_fenced_count": 1, "zero_linked_tasks_goals": 1, "held_windows_count": 0, "items": [] },
          "balances": [
            { "keeper": "k1", "balance_milli": 800, "decayed_milli": "800", "last_event_unix": null, "owned_items": [] }
          ],
          "recent_events": [
            { "seq": 1, "at_unix": 1.0, "kind": "paid", "goal_id": "g1", "total_milli": 500, "allocations": [{ "keeper": "k1", "amount_milli": 500, "weight": 1 }] },
            { "seq": 2, "at_unix": 2.0, "kind": "purchased", "keeper": "k1", "item": "hat", "amount_milli": 100 },
            { "seq": 3, "at_unix": 3.0, "kind": "granted", "keeper": "k1", "amount_milli": 500, "reason": "bonus" },
            { "seq": 4, "at_unix": 4.0, "kind": "gifted", "from_keeper": "k1", "to_keeper": "k2", "amount_milli": 50, "reason": "thanks" },
            { "seq": 5, "at_unix": 5.0, "kind": "gifted_item", "from_keeper": "k1", "to_keeper": "k2", "item": "hat" },
            { "seq": 6, "at_unix": 6.0, "kind": "equipped", "keeper": "k2", "slot": "head", "choice": "hat" },
            { "seq": 7, "at_unix": 7.0, "kind": "half_life_set", "half_life": { "mode": "decay", "half_life_hours": 168, "half_life_sec": 604800.0 } },
            { "seq": 8, "at_unix": 8.0, "kind": "snapshot", "goal_id": "g1", "title": "Goal 1", "linked_task_count": 2 },
            { "seq": 9, "at_unix": 9.0, "kind": "payout_owed", "goal_id": "g1" },
            { "seq": 10, "at_unix": 10.0, "kind": "candidates", "goal_id": "g1", "observation": "candidates", "candidate_task_count": 2, "candidate_keeper_count": 1 },
            { "seq": 11, "at_unix": 11.0, "kind": "candidates_fenced", "goal_id": "g2", "observation": "backlog_fenced", "candidate_task_count": 0, "candidate_keeper_count": 0 },
            { "seq": 12, "at_unix": 12.0, "kind": "candidate_window_held", "goal_id": "g1", "task_count": 1 },
            { "seq": 13, "at_unix": 13.0, "kind": "candidate_window_released", "goal_id": "g1" },
            { "seq": 14, "at_unix": 14.0, "kind": "unattributed", "goal_id": "g2", "reason": "no_candidates", "observation": "backlog_fenced", "diagnostic_hint": "0 tasks linked" },
            { "seq": 15, "at_unix": 15.0, "kind": "payout_failed", "goal_id": "g2", "due_date": "2026-11-22" }
          ]
        }
      }|}
  in
  let cl = expect_ok "candle ledger 15 events" (Wire_work.decode_candle_ledger candle_json) in
  Alcotest.(check bool) "ledger_state missing" true (cl.ledger_state = Wire_work.Ledger_missing);
  Alcotest.(check (option (float 0.001))) "nullable half_life_sec" None cl.half_life_sec;
  Alcotest.(check int) "all 15 candle event kinds decoded" 15 (List.length cl.recent_events)

(* 4. Wire_knowledge: Board, Wiki (all 5 endpoints), World Memory, Keeper+World Memory Diff, Act_skip_line *)
let test_wire_knowledge () =
  let board_json =
    parse_json
      {|{
        "posts": [
          {
            "id": "p-2", "title": "Release check", "body": "All pass", "author": "k1",
            "hearth": "ops", "created_at_unix": 1795252000.0, "votes": 4, "comment_count": 3,
            "author_karma": 42, "succession_chain_root_id": "p-root-1", "chain_depth": 3, "is_signal": true
          }
        ],
        "count": 1, "sort_by": "recent", "signal_only": true
      }|}
  in
  let feed = expect_ok "board feed" (Wire_knowledge.decode_board_feed ~observed_at:t0 board_json) in
  let p = List.hd feed.posts in
  (* Absent post_kind/visibility stay None instead of silent fabrication *)
  Alcotest.(check bool) "absent post_kind is None" true (Option.is_none p.post_kind);
  Alcotest.(check bool) "absent visibility is None" true (Option.is_none p.visibility);
  (* Real Wiki index: slug, nested lint.counts omitting zero keys, Unreadable_page without page *)
  let wiki_index_json =
    parse_json
      {|{
        "schema_version": 1, "instance_id": "srv-1", "generated_at_unix": 1795252092.4,
        "data": {
          "pages_total": 2, "pages_readable": 1, "pages_unreadable": 1,
          "pages": [
            {
              "slug": "ops-runbook", "file": "ops-runbook.md", "title": "Ops Runbook",
              "summary": "Steps", "source": "direct_experience", "author": "k1",
              "created": "2026-11-01", "updated": "2026-11-21", "revision": 3,
              "tags": ["ops"], "backlink_count": 2, "outgoing_link_count": 1,
              "sources_count": 1, "hearsay_count": 0, "sha256": "abc123"
            }
          ],
          "unreadable_pages": [{ "file": "corrupt.md", "reason": "bad yaml" }],
          "lint": {
            "total_findings": 1,
            "counts": { "duplicate_title_candidates": 0, "unreadable_page": 1 },
            "log_hole_suppressed": false,
            "orphans": [],
            "duplicate_title_candidates": [],
            "findings": [{ "kind": "unreadable_page", "subject": "corrupt.md", "file": "corrupt.md", "reason": "bad yaml" }]
          }
        }
      }|}
  in
  let wi = expect_ok "wiki index" (Wire_knowledge.decode_wiki_index wiki_index_json) in
  Alcotest.(check string) "wiki slug" "ops-runbook" (List.hd wi.pages).slug;
  Alcotest.(check int) "unreadable finding count" 1 wi.lint.counts.unreadable_page;
  Alcotest.(check int) "omitted zero broken_link" 0 wi.lint.counts.broken_link;
  (* Wiki page detail: an external link carries a null [exists] *)
  let wiki_page_json =
    parse_json
      {|{
        "schema_version": 1, "instance_id": "srv-1", "generated_at_unix": 1795252092.4,
        "data": {
          "page": "ops-runbook", "slug": "ops-runbook", "file": "ops-runbook.md",
          "frontmatter": {
            "title": "Ops Runbook", "summary": "Steps", "source": "direct_experience",
            "author": "k1", "created": "2026-11-01", "updated": "2026-11-21", "revision": 3, "tags": ["ops"]
          },
          "sha256": "abc123",
          "body_markdown": "# Ops",
          "outgoing_links": [
            { "text": "Docs", "kind": "external", "target": "https://example.com", "raw": "[Docs](https://example.com)", "line": 4, "exists": null }
          ],
          "backlinks": ["home"],
          "lint_findings": []
        }
      }|}
  in
  let wp = expect_ok "wiki page" (Wire_knowledge.decode_wiki_page_detail wiki_page_json) in
  (match (List.hd wp.outgoing_links).target with
  | Wire_knowledge.Link_external url ->
      Alcotest.(check string) "external link keeps its url" "https://example.com" url
  | Wire_knowledge.Link_page _ | Wire_knowledge.Link_own_file _
  | Wire_knowledge.Link_invalid_name _ | Wire_knowledge.Link_unsupported _ ->
      Alcotest.fail "an external link decodes as Link_external");
  (* Wiki log, search, put *)
  let wl =
    expect_ok "wiki log"
      (Wire_knowledge.decode_wiki_log
         (parse_json
            {|{
              "total_lines": 1, "unknown_action": 0, "unreadable_line": 0, "limit": 50,
              "entries": [{ "idx": 0, "written_at_unix": 1795252000.0, "action": "create", "revision": 1, "page": "ops-runbook", "author": null, "note": null }]
            }|}))
  in
  Alcotest.(check (option string)) "log nullable author" None (List.hd wl.entries).author;
  let ws =
    expect_ok "wiki search"
      (Wire_knowledge.decode_wiki_search
         (parse_json
            {|{
              "query": "ops", "count": 1, "limit": 30,
              "results": [{
                "slug": "ops-runbook", "title": "Ops Runbook", "summary": "Steps", "source": "direct_experience",
                "updated": "2026-11-21", "revision": 3, "tags": ["ops"], "score": 1.5, "match_tier": "whole_query",
                "snippets": [{ "line": 1, "text": "# Ops" }]
              }]
            }|}))
  in
  Alcotest.(check int) "search results" 1 (List.length ws.results);
  let put_create =
    Wire_knowledge.encode_wiki_put_request
      {
        expected_revision = None;
        expected_sha256 = None;
        title = "New";
        summary = "S";
        source = Wire_knowledge.Source_research;
        tags = [];
        body = "hello";
        note = "create";
      }
  in
  Alcotest.(check bool) "put create omits expected_revision" false
    (Wire_common.has_field put_create "expected_revision");
  (* Real World Memory *)
  let world_mem =
    expect_ok "world memory"
      (Wire_knowledge.decode_world_memory
         (parse_json
            {|{
              "schema_version": 1, "instance_id": "srv-1", "generated_at_unix": 1795252092.0,
              "data": {
                "ledger_state": "available",
                "inventory": { "ledger_sha256": "dead", "claims_count": 2, "facts_count": 5, "conflicts_count": 1, "excluded_count": 0 },
                "claims": [{ "claim_id": "c1", "claim": "OCaml 5.5", "stage": "corroborated", "supporting_keepers": ["k1"], "support_count": 1, "has_source_bound": false }],
                "active_conflicts": [{
                  "conflict_id": "cf1", "description": "Port conflict", "member_count": 2,
                  "competing_claims": [{ "store_kind": "ordinary", "keeper_id": "k1", "path": null, "claim_sha256": "aa", "resolved": true, "claim": "8935", "category": "net", "origin": "observed", "first_seen_unix": 100.0, "last_seen_unix": 200.0 }]
                }],
                "briefing": { "status": "missing", "text": null, "source_ids_count": 0, "error": null, "building_pass": null },
                "librarian_writers": {
                  "writers": "running", "error": 0, "warn": 1,
                  "keepers": [
                    { "keeper": "k1", "row": { "state": "idle" } },
                    { "keeper": "k2", "row": { "state": "asking" } },
                    { "keeper": "k3", "row": { "state": "resting" } },
                    { "keeper": "k4", "row": { "state": "refused_at_bottom" } }
                  ]
                }
              }
            }|}))
  in
  Alcotest.(check int) "claims_count" 2 world_mem.claims_count;
  Alcotest.(check bool) "briefing missing" true (world_mem.briefing.status = Wire_knowledge.Briefing_missing);
  (match world_mem.librarian_writers with
  | Wire_knowledge.Writers_running
      {
        keepers =
          [
            { state = Wire_knowledge.Writer_idle; _ };
            { state = Wire_knowledge.Writer_asking; _ };
            { state = Wire_knowledge.Writer_resting; _ };
            { state = Wire_knowledge.Writer_refused_at_bottom; _ };
          ];
        _;
      } ->
      ()
  | Wire_knowledge.Writers_none_in_process | Wire_knowledge.Writers_running _ ->
      Alcotest.fail "expected live idle/asking/resting/refused_at_bottom writer states");
  (* Real Keeper Memory Diff: nullable range, updated/retracted, retrieval_count, relation=revision, writer_status object *)
  let keeper_diff_fixture = parse_json
            {|{
              "schema_version": 1, "instance_id": "srv-1", "generated_at_unix": 1795252092.45,
              "data": {
                "scope": { "kind": "keeper", "keeper": "k1" },
                "range": { "window": "24h", "from_rev": null, "to_rev": 3828, "from_unix": 1795165692.0, "to_unix": 1795252092.0 },
                "counts": { "total_facts_now": 10, "added": 1, "updated": 1, "retracted": 1, "invalidated": 0, "journal_failures_in_window": 0, "journal_quarantines_in_window": 0, "undecodable_journal_lines": 0 },
                "retrieval_heat": { "hot": 4, "warm": 3, "cold": 2, "never_retrieved": 1, "total_events": 20, "unreadable_event_lines": 0 },
                "revisions": [{ "rev": 3828, "at_unix": 1795249100.0, "source": "librarian", "added": 1, "removed": 1, "invalidated": 0 }],
                "added": [{ "added_at_rev": 3828, "memory_id": "m1", "category": "ci", "origin": "derived", "text": "Fact A", "first_seen_unix": 1795249100.0, "last_seen_unix": 1795249100.0, "retrieval_count": 6, "last_retrieved_at_unix": null, "heat": "hot" }],
                "updated": [{
                  "relation": "revision", "at_rev": 3825,
                  "before": { "memory_id": "m0", "category": "ci", "origin": "derived", "text": "old", "first_seen_unix": 100.0, "last_seen_unix": 100.0, "retrieval_count": 0, "last_retrieved_at_unix": null, "heat": "never_retrieved" },
                  "after": { "memory_id": "m1", "category": "ci", "origin": "derived", "text": "new", "first_seen_unix": 200.0, "last_seen_unix": 200.0, "retrieval_count": 1, "last_retrieved_at_unix": 201.0, "heat": "hot" }
                }],
                "retracted": [{ "memory_id": "m-old", "category": "lane", "text": "gone", "removed_at_rev": 3821, "removed_by": "librarian", "drop_reason": null }],
                "invalidated": [],
                "writer_status": { "kind": "writer", "row": { "state": "resting" } }
              }
            }|} in
  let decode body = expect_ok "keeper memory diff" (Wire_knowledge.decode_memory_diff body) in
  let kdiff = decode keeper_diff_fixture in
  let covered coverage =
    match keeper_diff_fixture with
    | `Assoc envelope -> (match List.assoc "data" envelope with
      | `Assoc data -> (decode (`Assoc (("data", `Assoc (("coverage", coverage) :: data)) :: List.remove_assoc "data" envelope))).body
      | _ -> Alcotest.fail "expected data object")
    | _ -> Alcotest.fail "expected envelope" in
  let folded = `Assoc ["through_seq", `Int 3; "min_revision", `Int 1; "max_revision", `Int 2;
                       "min_at", `Float 1.; "max_at", `Float 3.] in
  (match covered (`Assoc ["status", `String "complete"; "folded_detail", folded]) with
   | Wire_knowledge.Keeper_diff { counts = { history_coverage = Some (Complete_with_retention f); _ }; _ } ->
     Alcotest.(check int) "recent complete response retains its historical boundary" 3 f.through_seq
   | _ -> Alcotest.fail "missing retention boundary");
  let partial = `Assoc ["status", `String "partial"; "folded_detail", folded; "retention_applies", `Bool true;
    "input_limited", `Bool true; "output_limited", `Bool true;
    "limit_causes", `List [`String "archive_bytes"; `String "result_rows"]; "conflicting_sequences", `Int 2;
    "missing_sequences", `List []; "unsequenced_in_window", `Int 0; "unplaced_in_revision_range", `Int 0;
    "unreadable_lines", `Int 1; "unresolved_successors", `Int 0; "snapshot_ahead", `Bool false; "snapshot_behind", `Bool false] in
  (match covered partial with
   | Wire_knowledge.Keeper_diff { counts = { history_coverage = Some (Partial_history p); _ }; _ } ->
     Alcotest.(check bool) "range, cause and damaged versus conflicting records remain distinguishable" true
       (p.retention_applies && p.limit_causes = [Archive_bytes; Result_rows] && p.missing_sequences = []
        && p.unreadable_lines = 1 && p.conflicting_sequences = 2)
   | _ -> Alcotest.fail "missing partial history");
  Alcotest.(check int) "heat_hot" 4 kdiff.retrieval_heat.hot;
  (match kdiff.body with
  | Wire_knowledge.Keeper_diff
      {
        writer_status =
          Some (Wire_knowledge.Keeper_writer_active { state = Wire_knowledge.Writer_resting; _ });
        _;
      } ->
      ()
  | Wire_knowledge.Keeper_diff _ | Wire_knowledge.World_diff _ ->
      Alcotest.fail "expected Keeper_writer_active Writer_resting");
  (* POST /memory/act still decodes "store": "open" *)
  let act_ans =
    expect_ok "memory act open"
      (Wire_knowledge.decode_memory_act_answer ~status_code:200
         (parse_json {|{ "store": "open" }|}))
  in
  Alcotest.(check bool) "memory act done open" true
    (act_ans = Wire_knowledge.Memory_act_done Wire_knowledge.Writer_open);
  (* World scope diff *)
  let wdiff =
    expect_ok "world memory diff"
      (Wire_knowledge.decode_memory_diff
         (parse_json
            {|{
              "scope": { "kind": "world" },
              "range": { "window": "24h", "from_rev": null, "to_rev": 5, "from_unix": 100.0, "to_unix": 200.0 },
              "counts": { "total_claims_now": 3, "added": 1, "updated": 1, "retracted": 0, "incomplete_batches": 0, "aborted_batches": 0 },
              "history": { "edge_changes": 2, "index_updates": 3, "digest_commits": 4, "missing_evidence": 5, "retained_from_seq": 2 },
              "retrieval_heat": { "hot": 1, "warm": 0, "cold": 0, "never_retrieved": 2, "total_events": 1, "unreadable_event_lines": 0 },
              "unparseable_timestamps": 0,
              "revisions": [
                { "rev": 4, "batch_id": "b1", "fact_id": "f1", "recorded_at": "2026-11-21T18:00:00Z", "op": "added" },
                { "rev": 5, "batch_id": "b2", "fact_id": "f1", "recorded_at": "2026-11-21T18:10:00Z", "op": "updated" }
              ],
              "added": [{ "seq": 4, "batch_id": "b1", "fact_id": "f1", "summary": "New claim", "claim_text": "Original claim", "recorded_at": "2026-11-21T18:00:00Z", "payload": {} }],
              "updated": [{ "seq": 5, "fact_id": "f1", "summary": "Revised claim", "before_text": "Original claim", "claim_text": "Current claim", "recorded_at": "2026-11-21T18:10:00Z", "before": null, "after": {} }],
              "retracted": []
            }|}))
  in
  (match wdiff.body with
  | Wire_knowledge.World_diff
      { counts = { total_claims_now = 3; added = 1; _ }
      ; history = Some { edge_changes = 2; index_updates = 3; digest_commits = 4; missing_evidence = 5; retained_from_seq = Some 2 }
      ; added = [{ claim_text = Some "Original claim"; _ }]
      ; updated = [{ before_text = Some "Original claim"; claim_text = Some "Current claim"; _ }]
      ; _
      } -> ()
  | Wire_knowledge.Keeper_diff _ | Wire_knowledge.World_diff _ ->
      Alcotest.fail "expected World_diff");
  (* Act_skip_line sends integer offset, NOT target *)
  let skip_req = Wire_knowledge.encode_memory_act_request (Wire_knowledge.Act_skip_line { offset = 128 }) in
  Alcotest.(check (list string)) "skip_line keys" [ "action"; "offset" ] (assoc_keys skip_req);
  Alcotest.(check int) "skip_line offset" 128
    (match json_field "offset" skip_req with
    | `Int n -> n
    | _ -> Alcotest.fail "expected int offset")

(* 5. Wire_runtime: $0 Sub/$0 Exhausted/? Unreported, real paths, nested probe, browser-lane, clients *)
let test_wire_runtime () =
  Alcotest.(check string) "efficiency path" "/api/v1/keeper-efficiency?month=2026-11"
    (Wire_runtime.keeper_efficiency_path ~month:"2026-11" ());
  Alcotest.(check string) "runtime probe path force=false"
    "/api/v1/dashboard/runtime-probe?force=false"
    (Wire_runtime.runtime_probe_path ~force:false ());
  Alcotest.(check string) "browser lane path"
    "/api/v1/dashboard/browser-lane/clients" Wire_runtime.browser_lane_path;
  let usage_json =
    parse_json
      {|{
        "provider_usage_windows_since": 1795200000.0,
        "provider_usage_windows": [
          {
            "scope": "account", "scope_id": "codex-pro",
            "providers": [ { "id": "openai", "display_name": "OpenAI Codex" } ],
            "state": "reported",
            "windows": [{ "limit_id": "5h", "window": { "kind": "five_hour" }, "role": "gates_model_calls", "utilization": { "unit": "percent", "value": 34 }, "resets_at": 1795260000.0, "observed_at": 1795252000.0 }]
          },
          {
            "scope": "account", "scope_id": "openrouter-empty",
            "providers": [ { "id": "openrouter", "display_name": "OpenRouter" } ],
            "state": "reported",
            "windows": [{ "limit_id": "credits", "window": { "kind": "provider_label", "label": "balance" }, "role": "gates_model_calls", "utilization": { "unit": "credit_balance", "currency": "USD", "total": 50.0, "remaining": 0.0 }, "resets_at": null, "observed_at": 1795252000.0 }]
          },
          {
            "scope": "account", "scope_id": "local-ollama",
            "providers": [ { "id": "ollama", "display_name": "Ollama" } ],
            "state": "not_reported_since_start",
            "windows": []
          }
        ]
      }|}
  in
  let u = expect_ok "provider usage windows" (Wire_runtime.decode_provider_usage_windows usage_json) in
  (match u.accounts with
  | [ sub; exh; unrep ] ->
      Alcotest.(check string) "$0 Sub" "$0 Sub" (Format_val.format_cost sub.cost_state ~lang:Say.Lang_en);
      Alcotest.(check string) "$0 Exhausted" "$0 Exhausted" (Format_val.format_cost exh.cost_state ~lang:Say.Lang_en);
      Alcotest.(check string) "? Unreported" "? Unreported" (Format_val.format_cost unrep.cost_state ~lang:Say.Lang_en)
  | _ -> Alcotest.fail "expected 3 usage accounts");
  (* Nested body.probe decoding *)
  let probe_json =
    parse_json
      {|{
        "generated_at": "2026-11-21T18:00:00Z",
        "cache_ttl_sec": 300.0,
        "cache_age_sec": 12.0,
        "cache_hit": true,
        "refresh_state": "fresh",
        "probe": {
          "status": "degraded",
          "probe_ok": false,
          "summary": { "runtimes": 2, "probed": 2, "reachable": 1, "failed": 1, "skipped": 0, "default_runtime_id": "rt-active" },
          "providers": [
            { "runtime_id": "rt-active", "transport": "http", "status": "reachable", "reachable": true, "latency_ms": 42.0, "checked_at": "2026-11-21T18:00:00Z" },
            { "runtime_id": "rt-outside", "transport": "http", "status": "auth_failed", "reachable": false, "error": "401", "checked_at": "2026-11-21T18:00:00Z" }
          ],
          "errors": ["rt-outside 401"],
          "observations": [],
          "limitations": []
        }
      }|}
  in
  let probe = expect_ok "nested runtime probe" (Wire_runtime.decode_runtime_probe probe_json) in
  let lanes = [ { Wire_runtime.id = "default"; declared = true; runtime_ids = [ "rt-active" ] } ] in
  let active_p, outside_p = Wire_runtime.partition_probe_by_active_lanes ~lanes probe in
  Alcotest.(check int) "active lane probes" 1 (List.length active_p);
  Alcotest.(check int) "outside lane probes" 1 (List.length outside_p);
  (* Real /api/v1/dashboard/browser-lane/clients & /api/v1/dashboard/clients *)
  let bl =
    expect_ok "browser lane"
      (Wire_runtime.decode_browser_lane
         (parse_json
            {|{
              "ok": true,
              "data": {
                "clients": [{ "clientId": "chrome-1" }],
                "inventoryIssues": [],
                "inventoryComplete": true,
                "automatic": { "browse": { "ok": true, "data": {} } }
              }
            }|}))
  in
  Alcotest.(check bool) "browser available" true bl.available;
  Alcotest.(check int) "browser client count" 1 bl.client_count;
  let clients =
    expect_ok "dashboard clients"
      (Wire_runtime.decode_mcp_clients
         (parse_json
            {|{
              "schema": "masc.dashboard.clients.v2",
              "clients": [{
                "name": "claude-desktop",
                "agent_type": "mcp_client",
                "keeper_name": null,
                "keeper_id": null,
                "status": "active",
                "current_task": null,
                "session_bound_at": "2026-11-21T18:00:00Z",
                "last_seen": "2026-11-21T18:04:00Z",
                "capabilities": ["tools"]
              }]
            }|}))
  in
  Alcotest.(check string) "client name" "claude-desktop" (List.hd clients).name

(* 6. Wire_infra: real /api/v1/infra/sandboxes & /api/v1/infra/sandboxes/:keeper *)
let test_wire_infra () =
  let sandboxes_json =
    parse_json
      {|{
        "schema_version": 1,
        "instance_id": "srv-84bc6b04",
        "generated_at_unix": 1795252092.42,
        "data": {
          "probe_state": { "kind": "warming", "measured_at_unix": 1795252085.10 },
          "summary": {
            "microvm_declared": 1, "microvm_running": 1, "microvm_sockets_present": 1,
            "microvm_shim_mismatch": 0, "ssh_pools": 1, "ssh_keepers": 1,
            "ssh_unbound_keepers": 1, "ssh_active_sessions": null, "ssh_max_sessions": 8,
            "docker_keepers": 1
          },
          "microvm_guests": [
            {
              "keeper": "music-sensei",
              "backend": "apple_container",
              "guest_name": "masc-music-sensei",
              "presence": "present",
              "agent_socket": { "status": "socket_present", "exists": true, "path_basename": "agent.sock" },
              "shim_parity": { "status": "matched", "build_identity": "84bc6b04" },
              "network_mode": "policy",
              "guest_size": { "cpus": null, "memory_mib": 2048 },
              "volume": { "name": "masc-vol-music-sensei", "status": "declared" },
              "tool_metrics_24h": {
                "calls": 1842, "failures": 27, "failure_unclassified": 0, "p50_ms": 120.0, "p95_ms": 4120.0, "max_ms": 9000.0,
                "failure_classes": { "dependency_unavailable": 19, "runtime_failure": 3, "policy_rejection": 4, "workflow_rejection": 1, "operator_cancelled": 0 }
              }
            }
          ],
          "ssh_pools": [
            {
              "pool_name": "masc-ssh-review-team",
              "host": "127.0.0.1", "port": 22268,
              "unix_user": "ops-user", "remote_root": "/srv", "private_home": true,
              "max_sessions": 8, "active_sessions": null,
              "reachability": { "status": "probe_pending" },
              "accounts": [
                { "unix_user": "ops-user", "active_sessions": null, "max_sessions": 8, "keepers": ["code-reviewer"] }
              ],
              "keeper_sessions": [
                {
                  "keeper": "code-reviewer", "last_dispatch": null,
                  "tool_metrics_24h": {
                    "calls": 100, "failures": 1, "failure_unclassified": 0, "p95_ms": 500.0,
                    "failure_classes": { "dependency_unavailable": 0, "runtime_failure": 1, "policy_rejection": 0, "workflow_rejection": 0, "operator_cancelled": 0 }
                  }
                }
              ],
              "tool_metrics_24h": {
                "calls": 100, "failures": 1, "failure_unclassified": 0, "p95_ms": 500.0,
                "failure_classes": { "dependency_unavailable": 0, "runtime_failure": 1, "policy_rejection": 0, "workflow_rejection": 0, "operator_cancelled": 0 }
              }
            }
          ],
          "ssh_unbound_keepers": [
            { "keeper": "drifter", "backend": "remote_ssh", "binding_state": "unbound", "remote_endpoint": null }
          ],
          "docker_keepers": [
            { "keeper": "dock-1", "backend": "docker", "network_mode": "none" }
          ],
          "volume_gc_report": null,
          "host_storage": { "free_mib": 50000 },
          "tool_metrics_24h": {
            "calls": 1942, "failures": 28, "failure_unclassified": 0, "p95_ms": 4120.0,
            "failure_classes": { "dependency_unavailable": 19, "runtime_failure": 4, "policy_rejection": 4, "workflow_rejection": 1, "operator_cancelled": 0 }
          },
          "unobserved_reasons": [{ "scope": "remote_ssh_sessions", "reason": "ssh_active_sessions_unreported" }]
        }
      }|}
  in
  let sb = expect_ok "sandboxes" (Wire_infra.decode_sandboxes_snapshot ~observed_at:t0 sandboxes_json) in
  Alcotest.(check bool) "ssh_active_sessions null -> Unreported" true
    (Observed.equal Int.equal sb.ssh_active_sessions Observed.unreported);
  let pool = List.hd sb.ssh_pools in
  Alcotest.(check bool) "pool active_sessions null -> Unreported" true
    (Observed.equal Int.equal pool.active_sessions Observed.unreported);
  Alcotest.(check bool) "account active_sessions null -> Unreported" true
    (Observed.equal Int.equal (List.hd pool.accounts).active_sessions
       Observed.unreported);
  Alcotest.(check int) "1 unobserved reason object" 1 (List.length sb.unobserved_reasons);
  let guest = List.hd sb.microvm_guests in
  Alcotest.(check bool) "network_mode policy" true (guest.network_mode = Wire_infra.Net_policy);
  Alcotest.(check bool) "nullable cpus -> Absent" true
    (Observed.equal Int.equal guest.cpus Observed.absent);
  Alcotest.(check int) "failure_classes dependency_unavailable" 19
    guest.metrics_24h.failure_classes.dependency_unavailable;
  (* GET /api/v1/infra/sandboxes/:keeper *)
  let per_keeper =
    expect_ok "keeper sandbox detail"
      (Wire_infra.decode_keeper_sandbox ~observed_at:t0
         (parse_json
            {|{
              "schema_version": 1, "instance_id": "srv-1", "generated_at_unix": 1795252092.42,
              "data": {
                "keeper": "dock-1",
                "probe_state": { "kind": "fresh", "measured_at_unix": 1795252090.0 },
                "sandbox": { "keeper": "dock-1", "backend": "docker", "network_mode": "none" }
              }
            }|}))
  in
  (match per_keeper.sandbox with
  | Wire_infra.Sandbox_docker { keeper = "dock-1"; network_mode = Wire_infra.Net_none; _ } -> ()
  | Wire_infra.Sandbox_microvm _ | Wire_infra.Sandbox_ssh_keeper _
  | Wire_infra.Sandbox_ssh_unbound _ | Wire_infra.Sandbox_docker _ ->
      Alcotest.fail "expected Sandbox_docker")

(* 7. Wire_config: Pref_board_sort "sort", real /config/schema categories, Set_string_array "value", diff_hunks *)
let test_wire_config () =
  let pref_sort = Wire_config.encode_tui_preference_change (Wire_config.Pref_board_sort "hot") in
  Alcotest.(check string) "Pref_board_sort sends key 'sort'" "hot"
    (expect_ok "sort" (Wire_common.required_nonblank_string pref_sort "sort"));
  let schema_json =
    parse_json
      {|{
        "schema_version": 1, "instance_id": "srv-1", "generated_at_unix": 1795252092.5,
        "data": {
          "target": "runtime",
          "file_exists": true,
          "file_sha256": "a19d4e7f",
          "categories": [
            {
              "id": "runtime_providers",
              "title": "Runtime & Providers",
              "field_count": 2,
              "fields": [
                {
                  "table": "providers.openrouter",
                  "key": "api_key",
                  "full_key": "providers.openrouter.api_key",
                  "type": "secret",
                  "secret": true,
                  "writable": true,
                  "current_value": { "kind": "secret_state", "configured": true, "masked": "[REDACTED]", "source": "env:OPENROUTER_API_KEY" },
                  "default_value": null,
                  "provenance": "env_override",
                  "reload_scope": "hot_reload",
                  "description": "OpenRouter API key"
                },
                {
                  "table": "",
                  "key": "port",
                  "full_key": "MASC_PORT",
                  "env": "MASC_PORT",
                  "type": "integer",
                  "range": { "kind": "integer", "min_inclusive": 1024, "max_inclusive": 65535 },
                  "secret": false,
                  "writable": false,
                  "current_value": "8935",
                  "default_value": "8935",
                  "provenance": "project",
                  "reload_scope": "restart_required",
                  "description": "Listen port"
                }
              ]
            }
          ]
        }
      }|}
  in
  let sc = expect_ok "config schema" (Wire_config.decode_config_schema schema_json) in
  let sec = List.hd sc.sections in
  Alcotest.(check bool) "tab mapping" true
    (Wire_config.settings_tab_of_category sec.category = Nav.Settings_providers_models);
  let f1 = List.nth sec.fields 1 in
  Alcotest.(check string) "empty table permitted for env-only key" "" f1.table;
  Alcotest.(check bool) "stringified integer current_value decoded as Val_int" true
    (f1.value = Wire_config.Val_int 8935);
  (* Raw string on a secret field MUST be rejected! *)
  let unredacted =
    parse_json
      {|{
        "target": "runtime", "file_exists": true, "file_sha256": "abc",
        "categories": [{
          "id": "runtime_providers", "title": "Leak", "field_count": 1,
          "fields": [{
            "table": "providers", "key": "api_key", "full_key": "providers.api_key",
            "type": "secret", "secret": true, "writable": true,
            "current_value": "sk-RAW-LEAK", "default_value": null,
            "provenance": "project", "reload_scope": "hot_reload", "description": "k"
          }]
        }]
      }|}
  in
  ignore (expect_err "reject raw unredacted secret" (Wire_config.decode_config_schema unredacted) : string);
  (* Set_string_array MUST send "value" key *)
  let patch_req =
    Wire_config.encode_patch_request
      {
        target = Wire_config.Target_keeper "wkbl-growth";
        keeper_name = None;
        expected_sha256 = Some "a19d4e7f";
        dry_run = true;
        ops = [ Wire_config.Set_string_array { table = "keeper"; key = "tags"; values = [ "a"; "b" ] } ];
      }
  in
  let ops_list =
    match json_field "ops" patch_req with
    | `List l -> l
    | _ -> Alcotest.fail "expected ops array"
  in
  Alcotest.(check bool) "set_string_array uses key 'value'" true
    (Wire_common.has_field (List.hd ops_list) "value");
  let patch_resp =
    expect_ok "patch response"
      (Wire_config.decode_patch_response
         (parse_json
            {|{
              "applied": false, "dry_run": true, "target": "keepers/wkbl-growth.toml",
              "changed": true, "before_sha256": "a19d4e7f", "new_sha256": "bbccdd",
              "snapshot_id": null, "reload_scope": "next_turn",
              "unified_diff": "--- a\n+++ b\n@@ -1,1 +1,1 @@\n-old\n+new",
              "diff_hunks": [{ "old_start": 1, "old_count": 1, "new_start": 1, "new_count": 1, "header": "@@ -1,1 +1,1 @@", "lines": ["-old", "+new"] }],
              "validation_warnings": []
            }|}))
  in
  Alcotest.(check int) "1 diff hunk" 1 (List.length patch_resp.diff_hunks);
  Alcotest.(check bool) "unified_diff non-empty" true (String.length patch_resp.unified_diff > 0)

(* Agent-core Custom payloads are untyped: provider telemetry arrives as a
   [ctor, object] tuple (keeper_event_bridge relays Telemetry_bus JSON). *)
let test_wire_observer_agent_core_payload_shapes () =
  let dec = Wire_observer.create_stream_decoder () in
  let frame id event_type payload =
    Printf.sprintf
      "id: %d\ndata: {\"type\":\"agent_core:%s\",\"event_type\":\"%s\",\"ts_unix\":1795252090.0,\"agent_name\":null,\"payload\":%s}\n\n"
      id event_type event_type payload
  in
  let chunk =
    frame 200 "telemetry_event"
      "[\"Streaming_first_chunk\",{\"provider\":\"anthropic\",\"ttfrc_ms\":412}]"
    ^ frame 201 "agent_completed" "{\"elapsed_s\":3.5,\"turn\":4}"
    ^ frame 202 "agent_completed" "[1,2]"
  in
  match
    List.map
      (fun (d : Wire_observer.delivery) -> d.decoded)
      (Wire_observer.feed_chunk dec chunk)
  with
  | [ Wire_observer.Event
        (Wire_observer.Agent_core { kind = Wire_observer.Telemetry; turn = None; _ });
      Wire_observer.Event
        (Wire_observer.Agent_core
           { kind = Wire_observer.Agent_completed { elapsed_s }; turn = Some 4; _ });
      Wire_observer.Undecodable _;
    ] ->
      Alcotest.(check (float 0.001)) "agent_completed elapsed_s" 3.5 elapsed_s
  | _ ->
      Alcotest.fail
        "telemetry tuple decodes; a kind that reads fields still needs an object"

(* 8. Wire_observer: tui_v2_dataset_changed & workspace_dataset_changed *)
let test_wire_observer () =
  let dec = Wire_observer.create_stream_decoder () in
  let chunk =
    "id: 100\ndata: {\"type\":\"tui_v2_dataset_changed\",\"dataset\":\"infra_sandboxes\",\"ts_unix\":1795252090.0}\n\n"
    ^ "id: 101\ndata: {\"type\":\"workspace_dataset_changed\",\"dataset\":\"wiki\"}\n\n"
    ^ "id: 102\ndata: {\"type\":\"msx_frame_ready\",\"slot\":1}\n\n"
    ^ "id: 103\ndata: {\"type\":\"dashboard_observation_changed\",\"payload\":{\"topic\":\"tool_metrics\",\"scope\":\"workspace\"}}\n\n"
  in
  let deliveries = Wire_observer.feed_chunk dec chunk in
  Alcotest.(check int) "4 deliveries" 4 (List.length deliveries);
  (match List.map (fun (d : Wire_observer.delivery) -> (d.cursor, d.decoded)) deliveries with
  | [ (Some 100, Wire_observer.Event (Wire_observer.Dataset_changed Wire_observer.Dataset_infra_sandboxes))
    ; (Some 101, Wire_observer.Event (Wire_observer.Dataset_changed Wire_observer.Dataset_wiki))
    ; (Some 102, Wire_observer.Event (Wire_observer.Ignored_legacy "msx_frame_ready"))
    ; (Some 103, Wire_observer.Event (Wire_observer.Observation_changed payload))
    ] ->
      Alcotest.(check bool) "observation topic tool_metrics" true (payload.topic = `Tool_metrics)
  | _ -> Alcotest.fail "unexpected observer decoded sequence");
  let req_cursor = Some { Sse_wire.instance_id = "inst-1"; event_id = 10 } in
  let headers =
    Sse_wire.observer_response_headers
      { instance_id = "inst-1"; replay = Sse_wire.Resumed_after_gap { missed_through = 25 } }
  in
  match Wire_observer.validate_handshake ~cursor:req_cursor ~headers with
  | Ok res -> Alcotest.(check bool) "gap triggers cold resync" true res.needs_cold_resync
  | Error _ -> Alcotest.fail "expected valid gap handshake"

(* 9. Ui_bus: keyed latest-wins coalescing + 512-cap exact Stream_gap overflow *)
let test_ui_bus () =
  let wakes = Atomic.make 0 in
  let bus =
    Ui_bus.create ~stream_capacity:Ui_bus.default_stream_capacity
      ~key_equal:String.equal ~key_hash:Hashtbl.hash
      ~on_wake:(fun () -> Atomic.incr wakes)
      ()
  in
  for i = 1 to 5 do
    Ui_bus.publish_snapshot bus ~key:"fleet" i
  done;
  Ui_bus.publish_snapshot bus ~key:"work" 99;
  Alcotest.(check int) "coalesced wake count" 1 (Atomic.get wakes);
  for i = 0 to 519 do
    Ui_bus.publish_stream bus i
  done;
  let items = Ui_bus.drain bus in
  Alcotest.(check int) "total drained items" 515 (List.length items);
  (match items with
  | Ui_bus.Snapshot ("fleet", 5)
    :: Ui_bus.Snapshot ("work", 99)
    :: Ui_bus.Stream_gap 8
    :: Ui_bus.Stream_event 8
    :: _ ->
      ()
  | _ -> Alcotest.fail "unexpected Ui_bus drain ordering or values");
  Alcotest.(check bool) "bus empty after drain" true (Ui_bus.is_empty bus)

let test_ui_bus_preserves_ordered_receipts () =
  let bus =
    Ui_bus.create ~stream_capacity:2 ~key_equal:String.equal ~key_hash:Hashtbl.hash ()
  in
  Ui_bus.publish_stream bus "lost delta";
  Ui_bus.publish_stream_receipt bus "interrupt acknowledged";
  Ui_bus.publish_stream_receipt bus "chat ended";
  Ui_bus.publish_stream bus "next turn started";
  Ui_bus.publish_stream bus "next turn delta";
  (match Ui_bus.drain_up_to ~max_items:2 bus with
  | [ Ui_bus.Stream_gap 1; Ui_bus.Stream_event "interrupt acknowledged" ] -> ()
  | _ -> Alcotest.fail "a displaced receipt is delivered after the real gap");
  match Ui_bus.drain bus with
  | [
      Ui_bus.Stream_event "chat ended";
      Ui_bus.Stream_event "next turn started";
      Ui_bus.Stream_event "next turn delta";
    ] ->
      ()
  | _ -> Alcotest.fail "a displaced completion must precede the next turn"

(* 10. Sse_hub (GET-only streams, backoff reset) + Http_client (CTL header sanitization, 409 sha256) *)
let test_sse_hub_and_http_client () =
  let ok_desired =
    [
      Sse_hub.Stream_spec.default_observer;
      Sse_hub.Stream_spec.default_fleet;
      Sse_hub.Stream_spec.model_metrics;
    ]
  in
  let validated = expect_ok "2 persistent + 1 view" (Sse_hub.validate_desired ok_desired) in
  Alcotest.(check int) "3 streams accepted" 3 (List.length validated);
  ignore
    (expect_err "reject >1 view-scoped stream"
       (Sse_hub.validate_desired (ok_desired @ [ Sse_hub.Stream_spec.logs () ]))
      : string);
  let next_desired =
    [
      Sse_hub.Stream_spec.default_observer;
      Sse_hub.Stream_spec.default_fleet;
      Sse_hub.Stream_spec.logs ~since_seq:50 ();
    ]
  in
  let diff = Sse_hub.diff_streams ~active:ok_desired ~desired:next_desired in
  Alcotest.(check int) "2 kept" 2 (List.length diff.kept);
  Alcotest.(check int) "1 to_stop" 1 (List.length diff.to_stop);
  Alcotest.(check int) "1 to_start" 1 (List.length diff.to_start);
  (* Backoff reset after healthy live session *)
  Alcotest.(check int) "live resets attempt to 1" 1
    (Sse_hub.next_reconnect_attempt ~prev_attempt:8 ~reached_live:true);
  Alcotest.(check int) "non-live increments attempt" 9
    (Sse_hub.next_reconnect_attempt ~prev_attempt:8 ~reached_live:false);
  (* Http_client header name & value CTL/NUL sanitization *)
  let ep =
    Http_client.make_endpoint ~host:"127.0.0.1" ~port:8935
      ~bearer_token:"tok\x00-secret\x7f"
      ~guard:
        {
          expected_instance = Some "srv-84bc6b04\r\n\x00Injected: bad";
          expected_workspace = Some "sha256-ws-99";
        }
      ()
  in
  let headers =
    Http_client.build_headers
      ~extra:[ ("Bad\r\nName", "val"); ("X-Clean", "ok\x00\x07!") ]
      ep
  in
  Alcotest.(check (option string)) "drop invalid CTL header name" None
    (List.assoc_opt "Bad\r\nName" headers);
  Alcotest.(check (option string)) "strip NUL & BEL from header value" (Some "ok!")
    (List.assoc_opt "X-Clean" headers);
  Alcotest.(check (option string)) "strip NUL & DEL from bearer" (Some "Bearer tok-secret")
    (List.assoc_opt "Authorization" headers);
  Alcotest.(check (option string)) "sanitize instance header"
    (Some "srv-84bc6b04  Injected: bad")
    (List.assoc_opt Http_client.expected_instance_header headers);
  (* 409 Conflict preserves observed_workspace_sha256 *)
  let body_409 =
    {|{
      "error": "workspace_mismatch",
      "code": "workspace_mismatch",
      "message": "server restarted",
      "expected_instance": "srv-old",
      "observed_instance": "srv-new",
      "observed_workspace_sha256": "sha-new-ws"
    }|}
  in
  match Http_client.classify_response ep ~status:409 ~body:body_409 with
  | Error
      (Http_client.Workspace_mismatch
        {
          expected_instance = Some "srv-old";
          observed_instance = Some "srv-new";
          observed_workspace_sha256 = Some "sha-new-ws";
          _;
        }) ->
      ()
  | Error
      ( Http_client.Workspace_mismatch _
      | Http_client.Transport _
      | Http_client.Http_error _
      | Http_client.Decode_error _ )
  | Ok _ ->
      Alcotest.fail "expected Workspace_mismatch with observed_workspace_sha256"

(* 11. Io_domain stream exception isolation + shutdown queue drain *)
let test_io_domain_isolation_and_shutdown () =
  Eio_main.run @@ fun env ->
  (* Part A: failing stream MUST NOT tear down sibling stream or Io_domain.run *)
  Eio.Switch.run (fun sw ->
      let io = Io_domain.start ~sw ~env in
      let captured_exn = Atomic.make false in
      let sibling_alive = Atomic.make false in
      let sibling_ready, set_sibling_ready = Eio.Promise.create () in
      let sibling_done, set_sibling_done = Eio.Promise.create () in
      let sibling =
        Io_domain.spawn_stream io (fun ~sw:_ ->
            Eio.Promise.resolve set_sibling_ready ();
            Eio.Promise.await sibling_done;
            Atomic.set sibling_alive true)
      in
      Eio.Promise.await sibling_ready;
      let bad =
        Io_domain.spawn_stream
          ~on_error:(fun _ -> Atomic.set captured_exn true)
          io
          (fun ~sw:_ -> raise (Invalid_argument "boom"))
      in
      Io_domain.await_stream_stopped bad;
      Alcotest.(check bool) "on_error invoked" true (Atomic.get captured_exn);
      Alcotest.(check bool) "sibling still running" false
        (Io_domain.is_stream_stopped sibling);
      let v = Io_domain.run io (fun () -> 99) in
      Alcotest.(check int) "Io_domain.run still healthy" 99 v;
      Eio.Promise.resolve set_sibling_done ();
      Io_domain.await_stream_stopped sibling;
      Alcotest.(check bool) "sibling finished cleanly" true (Atomic.get sibling_alive));
  (* Part B: closing Io_domain resolves pending run with Io_domain.Closed *)
  let io_ref = ref None in
  Eio.Switch.run (fun io_sw ->
      io_ref := Some (Io_domain.start ~sw:io_sw ~env));
  let closed_io = Option.get !io_ref in
  let got_closed =
    match Io_domain.run closed_io (fun () -> 1) with
    | _ -> false
    | exception Io_domain.Closed -> true
  in
  Alcotest.(check bool) "closed Io_domain raises Closed" true got_closed;
  let h = Io_domain.spawn_stream closed_io (fun ~sw:_ -> ()) in
  Io_domain.await_stream_stopped h;
  Alcotest.(check bool) "closed Io_domain stream immediately stopped" true
    (Io_domain.is_stream_stopped h)

(* 12. Worker_pool + Voice_runner: non-blocking flow, config decode, Cancel_ptt/Start_ptt session-ID race *)
let test_worker_and_voice_runner () =
  (* Pure voice config decoder *)
  let caps =
    expect_ok "voice config"
      (Voice_runner.decode_voice_config ~recorder_cmd:(Some "/usr/bin/rec")
         (parse_json
            {|{
              "ok": true,
              "tts": { "default_model": "m1", "active_endpoint": { "configured": true, "enabled": true } },
              "stt": { "default_model": "s1", "active_endpoint": { "configured": true, "enabled": false }, "send_on_stop": true }
            }|}))
  in
  Alcotest.(check bool) "stt_available" false caps.stt_available;
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let worker = Worker_pool.create ~sw (Eio.Stdenv.domain_mgr env) in
  Alcotest.(check int) "worker domain_count=1" 1 (Worker_pool.domain_count worker);
  let p =
    Worker_pool.submit_result_async worker ~sw ~name:"test_sum" (fun () -> Ok (21 + 21))
  in
  Alcotest.(check (result int string)) "worker sum" (Ok 42) (Eio.Promise.await p);
  (* Voice_runner Cancel_ptt -> immediate Start_ptt race: old session must NOT clobber new session *)
  let first_gate, release_first = Eio.Promise.create () in
  let cleaned_paths = ref [] in
  let session_counter = Atomic.make 0 in
  let transcript_p, resolve_transcript = Eio.Promise.create () in
  let backend : Voice_runner.backend =
    {
      probe =
        (fun () ->
          Ok
            {
              recorder_available = true;
              recorder_cmd = Some "rec";
              stt_available = true;
            });
      record_until_stopped =
        (fun ~device:_ ~stop_signal ~on_level ->
          let n = Atomic.fetch_and_add session_counter 1 + 1 in
          on_level (-18.0);
          Eio.Promise.await stop_signal;
          if n = 1 then Eio.Promise.await first_gate;
          Ok (Printf.sprintf "ptt_%d.wav" n));
      transcribe = (fun ~audio_path -> Ok ("heard:" ^ audio_path));
      cleanup_audio = (fun ~audio_path -> cleaned_paths := audio_path :: !cleaned_paths);
    }
  in
  let runner =
    Voice_runner.create ~sw ~backend ~on_event:(function
      | Voice_runner.Transcript_ready text ->
          ignore (Eio.Promise.try_resolve resolve_transcript text : bool)
      | Voice_runner.Phase_changed _ | Voice_runner.Level_meter _
      | Voice_runner.Capabilities _ | Voice_runner.Voice_error _ ->
          ())
  in
  (* Start #1, cancel #1 while #1 is blocked in shutdown, immediately start #2 *)
  Voice_runner.dispatch runner (Voice_runner.Start_ptt { device = None });
  Eio.Fiber.yield ();
  Voice_runner.dispatch runner Voice_runner.Cancel_ptt;
  Voice_runner.dispatch runner (Voice_runner.Start_ptt { device = None });
  Eio.Fiber.yield ();
  (* Now release #1 so its fiber finishes AFTER #2 has started *)
  Eio.Promise.resolve release_first ();
  Eio.Fiber.yield ();
  (* #2 MUST still be in Voice_recording (not clobbered to Voice_idle by #1) *)
  (match Voice_runner.phase runner with
  | Voice_runner.Voice_recording _ -> ()
  | Voice_runner.Voice_idle | Voice_runner.Voice_transcribing
  | Voice_runner.Voice_failed _ ->
      Alcotest.fail "stale cancelled session clobbered active second session");
  Alcotest.(check (list string)) "cancelled audio cleaned up" [ "ptt_1.wav" ] !cleaned_paths;
  Voice_runner.dispatch runner Voice_runner.Stop_ptt;
  let heard = Eio.Promise.await transcript_p in
  Alcotest.(check string) "second session transcript" "heard:ptt_2.wav" heard

let test_live_round1_wire_payloads () =
  (* P1-1: Live /api/v1/board emits "post_kind": "direct" for Human_post *)
  let live_board_json =
    parse_json
      {|{
        "posts": [
          {
            "id": "p-live-direct-1",
            "author": "operator",
            "author_karma": 12,
            "title": "Direct human post",
            "body": "Body text",
            "post_kind": "direct",
            "visibility": "internal",
            "created_at": 1795252000.0,
            "updated_at": 1795252010.0,
            "votes": 3,
            "score": 3,
            "comment_count": 1,
            "hearth": "ops",
            "succession_chain_root_id": null,
            "chain_depth": null
          },
          {
            "id": "p-live-auto-2",
            "author": "keeper-a",
            "title": "Automation post",
            "body": "Report",
            "post_kind": "automation",
            "visibility": "public",
            "created_at": 1795252020.0,
            "score": 1,
            "comment_count": 0
          }
        ],
        "count": 2,
        "sort_by": "recent",
        "signal_only": true
      }|}
  in
  let feed =
    expect_ok "live board with post_kind=direct"
      (Wire_knowledge.decode_board_feed ~observed_at:t0 live_board_json)
  in
  Alcotest.(check int) "2 board posts decoded" 2 (List.length feed.posts);
  (match (List.hd feed.posts).post_kind with
  | Some Wire_knowledge.Human_post -> ()
  | Some (Wire_knowledge.Automation_post | Wire_knowledge.System_post) | None ->
      Alcotest.fail "expected post_kind=direct -> Human_post");

  (* P1-2: Live /api/v1/dashboard/planning with criterion_review.state,
     structured Goal_measure JSON, and task_backlog counts object *)
  let live_planning_json =
    parse_json
      {|{
        "generated_at": "2026-11-22T06:00:00Z",
        "goals": [
          {
            "id": "g-count",
            "criterion_revision": "rev-1",
            "title": "Ship 3 stacks",
            "measure": { "kind": "count", "noun": "stack", "total": 3 },
            "procedure": "Merge all 3",
            "due_date": null,
            "priority": 1,
            "phase": "executing",
            "last_review_note": null,
            "last_review_at": null,
            "created_at": "2026-11-20T00:00:00Z",
            "updated_at": "2026-11-22T05:00:00Z",
            "criterion_review": {
              "state": "viable",
              "reason": "Count target is explicit"
            }
          },
          {
            "id": "g-qty",
            "criterion_revision": "rev-2",
            "title": "Cut latency",
            "measure": { "kind": "quantity", "unit": "ms", "direction": "at_most", "target": 50.0 },
            "procedure": "Benchmark p95",
            "due_date": "2026-11-30",
            "priority": 2,
            "phase": "verifying",
            "last_review_note": null,
            "last_review_at": null,
            "created_at": "2026-11-20T00:00:00Z",
            "updated_at": "2026-11-22T05:00:00Z",
            "criterion_review": { "state": "unchecked" }
          },
          {
            "id": "g-donewhen",
            "criterion_revision": "rev-3",
            "title": "Visual QA green",
            "measure": { "kind": "done_when", "condition": "All 37 PNGs pass gate" },
            "procedure": "Inspect PNGs",
            "due_date": null,
            "priority": 1,
            "phase": "executing",
            "last_review_note": null,
            "last_review_at": null,
            "created_at": "2026-11-20T00:00:00Z",
            "updated_at": "2026-11-22T05:00:00Z",
            "criterion_review": {
              "state": "needs_revision",
              "reason": "Add exact viewport list"
            }
          }
        ],
        "goal_history": { "unlisted": [] },
        "rollup": { "total": 3 },
        "task_backlog": {
          "todo": 2,
          "claimed": 1,
          "in_progress": 1,
          "awaiting_verification": 0,
          "done": 5,
          "cancelled": 0
        }
      }|}
  in
  let snap =
    expect_ok "live planning snapshot"
      (Wire_work.decode_planning_snapshot ~observed_at:t0 live_planning_json)
  in
  Alcotest.(check int) "3 live goals decoded" 3 (List.length snap.goals);
  let g0 = List.nth snap.goals 0 in
  let g1 = List.nth snap.goals 1 in
  let g2 = List.nth snap.goals 2 in
  Alcotest.(check string) "count measure formatted" "3 stack" g0.measure;
  Alcotest.(check string) "quantity measure formatted" "<= 50 ms" g1.measure;
  Alcotest.(check string) "done_when measure formatted" "All 37 PNGs pass gate" g2.measure;
  (match g0.criterion_verdict with
  | Wire_work.Criterion_valid -> ()
  | Wire_work.Criterion_pending | Wire_work.Criterion_invalid _
  | Wire_work.Criterion_unavailable _ ->
      Alcotest.fail "expected state=viable -> Criterion_valid");
  (match g1.criterion_verdict with
  | Wire_work.Criterion_pending -> ()
  | Wire_work.Criterion_valid | Wire_work.Criterion_invalid _
  | Wire_work.Criterion_unavailable _ ->
      Alcotest.fail "expected state=unchecked -> Criterion_pending");
  (match g2.criterion_verdict with
  | Wire_work.Criterion_invalid reason ->
      Alcotest.(check string) "needs_revision reason" "Add exact viewport list" reason
  | Wire_work.Criterion_pending | Wire_work.Criterion_valid
  | Wire_work.Criterion_unavailable _ ->
      Alcotest.fail "expected state=needs_revision -> Criterion_invalid");

  (* Live /api/v1/dashboard/execution?light=true tasks + linked_task_count enrichment *)
  let live_exec_json =
    parse_json
      {|{
        "generated_at": "2026-11-22T06:00:00Z",
        "tasks": [
          {
            "id": "task-101",
            "title": "Fix PTY EAGAIN",
            "description": "",
            "priority": 1,
            "files": [],
            "created_at": "2026-11-22T01:00:00Z",
            "updated_at": "2026-11-22T05:00:00Z",
            "status": "in_progress",
            "assignee": "visual-polish-1",
            "started_at": "2026-11-22T04:00:00Z",
            "goal_id": "g-count"
          },
          {
            "id": "task-102",
            "title": "Unlinked task",
            "description": "Details",
            "priority": 2,
            "files": [],
            "created_at": "2026-11-22T02:00:00Z",
            "updated_at": "2026-11-22T02:00:00Z",
            "status": "todo",
            "assignee": null,
            "goal_id": null
          }
        ]
      }|}
  in
  let tasks =
    expect_ok "live execution tasks"
      (Wire_work.decode_execution_tasks live_exec_json)
  in
  Alcotest.(check int) "2 live tasks decoded" 2 (List.length tasks);
  let enriched = Wire_work.enrich_planning_with_tasks ~observed_at:t0 snap tasks in
  Alcotest.(check int) "enriched has 2 tasks" 2 (List.length enriched.tasks);
  let g0_e = List.nth enriched.goals 0 in
  let g1_e = List.nth enriched.goals 1 in
  Alcotest.(check (option int)) "g-count linked_task_count=1" (Some 1)
    (Observed.to_option g0_e.linked_task_count);
  Alcotest.(check (option int)) "g-qty linked_task_count=0" (Some 0)
    (Observed.to_option g1_e.linked_task_count)

let test_round2_wire_regressions () =
  (* R2-P1-1: Secret schema rows accept safe unset/redacted default_value display strings
     as None, while STILL strictly rejecting real leaked secret strings on both
     current_value and default_value. *)
  let make_secret_schema ~cur_json ~def_json =
    parse_json
      (Printf.sprintf
         {|{
           "target": "runtime", "file_exists": true, "file_sha256": "abc123",
           "categories": [{
             "id": "runtime_providers", "title": "Providers", "field_count": 1,
             "fields": [{
               "table": "providers", "key": "api_key", "full_key": "providers.api_key",
               "type": "secret", "secret": true, "writable": true,
               "current_value": %s,
               "default_value": %s,
               "provenance": "env_override", "reload_scope": "hot_reload", "description": "API key"
             }]
           }]
         }|}
         cur_json def_json)
  in
  let safe_cur =
    {|{ "kind": "secret_state", "configured": false, "masked": "", "source": "unset" }|}
  in
  List.iter
    (fun def_json ->
      let sc =
        expect_ok ("safe secret default " ^ def_json)
          (Wire_config.decode_config_schema
             (make_secret_schema ~cur_json:safe_cur ~def_json))
      in
      let f = List.hd (List.hd sc.sections).fields in
      Alcotest.(check bool) ("secret default_value is None for " ^ def_json)
        true (Option.is_none f.default_value))
    [ "null"; {|""|}; {|"(unset)"|}; {|"[REDACTED]"|} ];
  let err_def =
    expect_err "reject real leaked secret in default_value"
      (Wire_config.decode_config_schema
         (make_secret_schema ~cur_json:safe_cur ~def_json:{|"sk-RAW-DEFAULT-LEAK"|} ))
  in
  Alcotest.(check bool) "default_value leak error mentions secret redaction" true
    (String.length err_def > 0);
  let err_cur =
    expect_err "reject real leaked secret in current_value"
      (Wire_config.decode_config_schema
         (make_secret_schema ~cur_json:{|"sk-RAW-CURRENT-LEAK"|} ~def_json:"null"))
  in
  Alcotest.(check bool) "current_value leak error mentions secret redaction" true
    (String.length err_cur > 0);

  (* /api/v1/dashboard/gate: approval_queue is read through
     approval_queue_state (ready or unavailable). *)
  let live_gate_json =
    parse_json
      {|{
        "generated_at": "2026-11-22T06:00:00Z",
        "approval_queue": [
          {
            "id": "gate-42",
            "keeper_name": "wkbl-growth",
            "tool_name": "masc_shell",
            "input_preview": "git status",
            "waiting_s": 14.5,
            "phase": "human_required"
          }
        ],
        "approval_queue_state": { "state": "ready" }
      }|}
  in
  let live_gates =
    expect_ok "live gate approval_queue"
      (Wire_work.decode_gate_pending_list live_gate_json)
  in
  Alcotest.(check int) "1 live gate decoded" 1 (List.length live_gates);
  let g0 = List.hd live_gates in
  Alcotest.(check string) "gate id" "gate-42" g0.id;
  Alcotest.(check string) "gate keeper" "wkbl-growth" g0.keeper;
  Alcotest.(check string) "gate tool_name" "masc_shell" g0.tool_name;
  Alcotest.(check string) "gate phase" "human_required" g0.phase;
  let empty_gates =
    expect_ok "live gate empty approval_queue"
      (Wire_work.decode_gate_pending_list
         (parse_json
            {|{ "approval_queue": [], "approval_queue_state": { "state": "ready" } }|}))
  in
  Alcotest.(check int) "0 live gates" 0 (List.length empty_gates);
  (* An unreadable queue store is a failed read, not an empty queue. *)
  Alcotest.(check string) "unavailable approval queue is an error"
    "Approval queue unavailable: queue file corrupt"
    (expect_err "unavailable approval queue"
       (Wire_work.decode_gate_pending_list
          (parse_json
             {|{ "approval_queue": null,
                 "approval_queue_state": { "state": "unavailable", "code": "reset_required",
                   "title": "Approval queue unavailable", "operator_detail": "queue file corrupt",
                   "severity": "critical", "icon": "alert" } }|})));

  (* R2-P1-4: /api/v1/infra/sandboxes/:keeper live remote_ssh {keeper, backend, pool, session}
     and unbound SSH keeper (binding_state). *)
  let live_ssh_keeper_json =
    parse_json
      {|{
        "schema_version": 1, "instance_id": "srv-1", "generated_at_unix": 1795252092.42,
        "data": {
          "keeper": "ssh-coder",
          "probe_state": { "kind": "fresh", "measured_at_unix": 1795252090.0 },
          "sandbox": {
            "keeper": "ssh-coder",
            "backend": "remote_ssh",
            "pool": {
              "pool_name": "gpu-box-1",
              "host": "10.0.0.8",
              "port": 22,
              "unix_user": "masc",
              "remote_root": "/srv/masc",
              "private_home": true,
              "max_sessions": 4,
              "active_sessions": 1,
              "reachability": { "status": "reachable", "rtt_ms": 11.4, "measured_at_unix": 1795252090.0 },
              "accounts": [{ "unix_user": "masc", "active_sessions": 1, "max_sessions": 4, "keepers": ["ssh-coder"] }],
              "keeper_sessions": []
            },
            "session": {
              "keeper": "ssh-coder",
              "last_dispatch": "2026-11-22T05:59:00Z"
            }
          }
        }
      }|}
  in
  let ssh_resp =
    expect_ok "live remote_ssh keeper sandbox"
      (Wire_infra.decode_keeper_sandbox ~observed_at:t0 live_ssh_keeper_json)
  in
  (match ssh_resp.sandbox with
  | Wire_infra.Sandbox_ssh_keeper { session; pool = Some p } ->
      Alcotest.(check string) "ssh session keeper" "ssh-coder" session.keeper;
      Alcotest.(check string) "ssh embedded pool_name" "gpu-box-1" p.pool_name;
      Alcotest.(check int) "ssh embedded max_sessions" 4 p.max_sessions
  | Wire_infra.Sandbox_ssh_keeper { pool = None; _ }
  | Wire_infra.Sandbox_microvm _
  | Wire_infra.Sandbox_ssh_unbound _
  | Wire_infra.Sandbox_docker _ ->
      Alcotest.fail "expected Sandbox_ssh_keeper with embedded pool");
  let unbound_ssh_json =
    parse_json
      {|{
        "schema_version": 1, "instance_id": "srv-1", "generated_at_unix": 1795252092.42,
        "data": {
          "keeper": "ssh-unbound-1",
          "sandbox": {
            "keeper": "ssh-unbound-1",
            "backend": "remote_ssh",
            "binding_state": "unbound",
            "remote_endpoint": "ssh://10.0.0.9"
          }
        }
      }|}
  in
  let unbound_resp =
    expect_ok "unbound remote_ssh keeper sandbox"
      (Wire_infra.decode_keeper_sandbox ~observed_at:t0 unbound_ssh_json)
  in
  match unbound_resp.sandbox with
  | Wire_infra.Sandbox_ssh_unbound u ->
      Alcotest.(check string) "unbound keeper" "ssh-unbound-1" u.keeper;
      Alcotest.(check string) "unbound binding_state" "unbound" u.binding_state
  | Wire_infra.Sandbox_microvm _
  | Wire_infra.Sandbox_ssh_keeper _
  | Wire_infra.Sandbox_docker _ ->
      Alcotest.fail "expected Sandbox_ssh_unbound"

let test_round3_wire_config_unset_sentinels () =
  (* R3-P1-1: non-secret Registry.all sentinel display strings on boolean/float/int
     current_value decode cleanly to Val_null (and display strings like "(failsafe 30)"
     decode cleanly without failing the entire schema), while secret fields STILL
     strictly enforce secret_state objects even for sentinel-looking strings. *)
  let non_secret_schema =
    parse_json
      {|{
        "schema_version": 1, "instance_id": "srv-1", "generated_at_unix": 1795252092.5,
        "data": {
          "target": "runtime",
          "file_exists": true,
          "file_sha256": "deadbeef",
          "categories": [
            {
              "id": "routing_failover",
              "title": "Routing & Failover Lanes",
              "field_count": 1,
              "fields": [
                {
                  "table": "runtime",
                  "key": "default",
                  "full_key": "runtime.default",
                  "type": "string",
                  "secret": false,
                  "writable": true,
                  "current_value": "lane.primary",
                  "default_value": null,
                  "provenance": "project",
                  "reload_scope": "hot_reload",
                  "description": "Default lane"
                }
              ]
            },
            {
              "id": "keepers_autonomy",
              "title": "Keepers & Autonomy",
              "field_count": 4,
              "fields": [
                {
                  "table": "turn",
                  "key": "enable_thinking",
                  "full_key": "turn.enable_thinking",
                  "env": "MASC_KEEPER_ENABLE_THINKING",
                  "type": "boolean",
                  "secret": false,
                  "writable": true,
                  "current_value": "unset (provider default)",
                  "default_value": "unset (provider default)",
                  "provenance": "default",
                  "reload_scope": "restart_required",
                  "description": "Enable thinking"
                },
                {
                  "table": "",
                  "key": "MASC_KEEPER_BODY_TIMEOUT_SEC",
                  "full_key": "MASC_KEEPER_BODY_TIMEOUT_SEC",
                  "env": "MASC_KEEPER_BODY_TIMEOUT_SEC",
                  "type": "float",
                  "range": { "kind": "float", "min_inclusive": 1.0, "min_exclusive": null, "max_inclusive": 600.0 },
                  "secret": false,
                  "writable": false,
                  "current_value": "(none)",
                  "default_value": "(none)",
                  "provenance": "default",
                  "reload_scope": "restart_required",
                  "description": "Body timeout"
                },
                {
                  "table": "turn",
                  "key": "batch_limit",
                  "full_key": "turn.batch_limit",
                  "type": "integer",
                  "secret": false,
                  "writable": true,
                  "current_value": "(unset)",
                  "default_value": "5",
                  "provenance": "default",
                  "reload_scope": "restart_required",
                  "description": "Batch limit"
                },
                {
                  "table": "turn",
                  "key": "stream_idle_timeout_sec",
                  "full_key": "turn.stream_idle_timeout_sec",
                  "type": "float",
                  "secret": false,
                  "writable": true,
                  "current_value": "(failsafe 30)",
                  "default_value": "(failsafe 30)",
                  "provenance": "default",
                  "reload_scope": "restart_required",
                  "description": "Stream idle"
                }
              ]
            }
          ]
        }
      }|}
  in
  let decoded =
    expect_ok "R3-P1-1 unset sentinel schema"
      (Wire_config.decode_config_schema non_secret_schema)
  in
  Alcotest.(check int) "2 sections decoded" 2 (List.length decoded.sections);
  let routing_sec = List.nth decoded.sections 0 in
  Alcotest.(check bool) "routing_failover maps to Cat_routing_failover" true
    (routing_sec.category = Wire_config.Cat_routing_failover);
  Alcotest.(check bool) "Cat_routing_failover maps to Settings_routing_failover" true
    (Wire_config.settings_tab_of_category routing_sec.category
     = Nav.Settings_routing_failover);
  let keeper_fields = (List.nth decoded.sections 1).fields in
  let find_f k =
    List.find (fun (f : Wire_config.schema_field) -> String.equal f.full_key k)
      keeper_fields
  in
  Alcotest.(check bool) "turn.enable_thinking unset sentinel -> Val_null" true
    ((find_f "turn.enable_thinking").value = Wire_config.Val_null);
  Alcotest.(check bool) "MASC_KEEPER_BODY_TIMEOUT_SEC (none) -> Val_null" true
    ((find_f "MASC_KEEPER_BODY_TIMEOUT_SEC").value = Wire_config.Val_null);
  Alcotest.(check bool) "turn.batch_limit (unset) -> Val_null" true
    ((find_f "turn.batch_limit").value = Wire_config.Val_null);
  Alcotest.(check bool) "non-secret display string preserved as Val_string" true
    ((find_f "turn.stream_idle_timeout_sec").value
     = Wire_config.Val_string "(failsafe 30)");
  (* Secret field MUST still reject sentinel-looking raw strings on current_value *)
  List.iter
    (fun raw_cur ->
      let bad_secret =
        parse_json
          (Printf.sprintf
             {|{
               "target": "runtime", "file_exists": true, "file_sha256": "abc",
               "categories": [{
                 "id": "runtime_providers", "title": "Providers", "field_count": 1,
                 "fields": [{
                   "table": "providers", "key": "api_key", "full_key": "providers.api_key",
                   "type": "secret", "secret": true, "writable": true,
                   "current_value": %S, "default_value": null,
                   "provenance": "project", "reload_scope": "hot_reload", "description": "k"
                 }]
               }]
             }|}
             raw_cur)
      in
      ignore
        (expect_err ("secret rejects raw current_value " ^ raw_cur)
           (Wire_config.decode_config_schema bad_secret)
          : string))
    [ "(none)"; "unset (provider default)"; ""; "sk-RAW-LEAK" ]

let test_v25_data_pipeline_decoders () =
  let t0 = Clock.Mono.of_ns 1_000_000_000L in
  (* 1. Cache hit formula fix: cache_read is a subset of inclusive input_tokens *)
  (match
     Wire_runtime.compute_cache_hit_pct ~input_tokens:3_032_473_974
       ~cache_read_tokens:2_970_818_611
   with
  | Some pct ->
      Alcotest.(check bool) "cache hit ~97.97% (not capped at 49.5%)" true
        (pct > 97.5 && pct < 98.5)
  | None -> Alcotest.fail "expected Some cache_hit_pct");
  (match
     Wire_runtime.compute_cache_hit_pct ~input_tokens:100
       ~cache_read_tokens:150
   with
  | Some pct ->
      Alcotest.(check (float 0.01)) "clamped to 100.0" 100.0 pct
  | None -> Alcotest.fail "expected clamped Some 100.0");
  (* 2. models/metrics query param + hourly bucket aggregation + runtime/metrics *)
  Alcotest.(check string) "models_metrics_path exact bucket_min param"
    "/api/v1/models/metrics?window=1440&bucket_min=60"
    (Wire_runtime.models_metrics_path ~window_minutes:1440 ~bucket_minutes:60);
  Alcotest.(check string) "models metrics stream asks for the chart window"
    "/api/v1/models/metrics/stream?window=1440&bucket_min=60"
    Wire_runtime.models_metrics_stream_path;
  let models_metrics_json =
    parse_json
      {|{
        "window_minutes": 1440,
        "bucket_minutes": 60,
        "total_entries": 30,
        "total_error_entries": 1,
        "models": [
          {
            "model_id": "claude-opus-4-6",
            "entry_count": 20,
            "success_count": 19,
            "error_count": 1,
            "p95_latency_ms": 4200.0,
            "total_input_tokens": 100000,
            "total_output_tokens": 5000,
            "total_cache_read_tokens": 90000,
            "total_cache_creation_tokens": 2000,
            "cached_input": { "input_tokens": 100000, "cache_read_tokens": 90000, "sample_count": 20 },
            "total_cost_usd": 1.25,
            "total_tool_calls": 40,
            "buckets": [
              { "ts_start": 1795250000.0, "entry_count": 10, "success_count": 10, "error_count": 0, "p95_latency_ms": 3000.0, "error_rate": 0.0, "total_cost_usd": 0.50, "cache_hit_ratio": 0.85 },
              { "ts_start": 1795253600.0, "entry_count": 10, "success_count": 9, "error_count": 1, "p95_latency_ms": 4200.0, "error_rate": 0.1, "total_cost_usd": 0.75, "cache_hit_ratio": 0.95 }
            ]
          },
          {
            "model_id": "gpt-5.4",
            "entry_count": 10,
            "success_count": 10,
            "error_count": 0,
            "p95_latency_ms": 2100.0,
            "total_input_tokens": 50000,
            "total_output_tokens": 3000,
            "total_cache_read_tokens": 45000,
            "total_cost_usd": 0.25,
            "total_tool_calls": 10,
            "buckets": [
              { "ts_start": 1795253600.0, "entry_count": 10, "success_count": 10, "error_count": 0, "p95_latency_ms": 2100.0, "error_rate": 0.0, "total_cost_usd": 0.25, "cache_hit_ratio": 0.75 }
            ]
          }
        ]
      }|}
  in
  let mm =
    expect_ok "decode_models_metrics"
      (Wire_runtime.decode_models_metrics ~observed_at:t0 models_metrics_json)
  in
  Alcotest.(check int) "2 hourly buckets merged chronologically" 2
    (List.length mm.hourly_buckets);
  let b1 = List.nth mm.hourly_buckets 1 in
  Alcotest.(check int) "merged bucket entry_count = 20" 20 b1.entry_count;
  Alcotest.(check (float 0.01)) "merged bucket cost = 1.0" 1.0 b1.total_cost_usd;
  Alcotest.(check (option (float 0.1))) "weighted cache_hit_pct = 85.0"
    (Some 85.0) b1.cache_hit_pct;
  Alcotest.(check (option (float 0.01))) "fleet cost = 1.50" (Some 1.50)
    (Observed.to_option mm.fleet_cost_usd);
  Alcotest.(check (option (float 0.1))) "fleet cache hit = 90.0" (Some 90.0)
    (Observed.to_option mm.fleet_cache_hit_pct);
  let rm_unavail =
    expect_ok "decode_runtime_metrics unavailable"
      (Wire_runtime.decode_runtime_metrics ~observed_at:t0
         (parse_json {|{"history":{"state":"unavailable","reason":"disabled"}}|}))
  in
  Alcotest.(check bool) "runtime metrics unavailable state" true
    (match rm_unavail.state with
    | Wire_runtime.Runtime_metrics_unavailable "disabled" -> true
    | Wire_runtime.Runtime_metrics_unavailable _
    | Wire_runtime.Runtime_metrics_ready ->
        false);
  let rm_ready =
    expect_ok "decode_runtime_metrics ready"
      (Wire_runtime.decode_runtime_metrics ~observed_at:t0
         (parse_json
            {|{
              "history": {
                "state": "ready",
                "observed_at": 1795254000.0,
                "window_minutes": 1440,
                "attributed_entries": 10,
                "unattributed_entries": 2,
                "runtimes": [
                  {
                    "runtime_id": "alice.opus",
                    "entry_count": 10,
                    "success_count": 10,
                    "error_count": 0,
                    "cached_input": { "input_tokens": 100000, "cache_read_tokens": 92000, "sample_count": 10 },
                    "total_cost_usd": 0.45
                  }
                ]
              }
            }|}))
  in
  Alcotest.(check (option (float 0.1))) "runtime_metrics fleet cache hit = 92.0"
    (Some 92.0) (Observed.to_option rm_ready.fleet_cache_hit_pct);
  (* 3. Real provider-usage-history flat point schema + live 8935 tool_series *)
  let hist_json =
    parse_json
      {|{
        "status": "ready",
        "days": 7,
        "generated_at": 1795254000.0,
        "unreadable_reports": 0,
        "reported_no_windows": [
          { "scope_id": "antigravity_e5f60718", "observed_at": 1795253900.0 }
        ],
        "points": [
          {
            "scope_id": "claude_code_a1b2c3d4",
            "source": "oauth_api",
            "kind": "five_hour",
            "observed_at": 1795253950.0,
            "resets_at": 1795260000.0,
            "unit": "percent",
            "value": 42
          },
          {
            "scope_id": "openrouter",
            "source": "credit_api",
            "kind": "credit_balance",
            "observed_at": 1795253950.0,
            "unit": "credit_balance",
            "currency": "USD",
            "total": 50.0,
            "remaining": 12.5
          }
        ]
      }|}
  in
  (match
     expect_ok "decode_provider_usage_history"
       (Wire_runtime.decode_provider_usage_history hist_json)
   with
  | Wire_runtime.Usage_history_ready { days = 7; points; reported_no_windows; _ } ->
      Alcotest.(check int) "2 history points" 2 (List.length points);
      Alcotest.(check int) "1 no-window report" 1
        (List.length reported_no_windows)
  | Wire_runtime.Usage_history_ready _ | Wire_runtime.Usage_history_unavailable _ ->
      Alcotest.fail "expected Usage_history_ready");
  let live_tool_series =
    expect_ok "live 8935 tool_series shape"
      (Wire_runtime.decode_tool_series
         (parse_json
            {|{
              "generated_at": 1795254000.0,
              "bucket": "hour",
              "utc_offset_min": 540,
              "series": [
                { "start": 1795250000.0, "call_count": 0, "failure_count": 0, "p95_ms": 0.0 },
                { "start": 1795253600.0, "call_count": 25, "failure_count": 1, "p95_ms": 480.0 }
              ]
            }|}))
  in
  Alcotest.(check int) "2 live tool_series buckets" 2
    (List.length live_tool_series.buckets);
  (* 4. Human provider alias resolution *)
  let runtimes : Wire_runtime.runtime_option list =
    [
      { id = "alice.opus"; provider_id = "claude_code_a1b2c3d4"; provider = "claude_code_a1b2c3d4"; model = Some "claude-opus-4-6"; declared_reasoning_effort = None; transport = Some "cli"; is_default = true };
      { id = "bob.sonnet"; provider_id = "claude_code_b2c3d4e5"; provider = "claude_code_b2c3d4e5"; model = Some "claude-sonnet-4-6"; declared_reasoning_effort = None; transport = Some "cli"; is_default = false };
      { id = "carol.sonnet"; provider_id = "claude_code_c3d4e5f6"; provider = "claude_code_c3d4e5f6"; model = Some "claude-sonnet-4-6"; declared_reasoning_effort = None; transport = Some "cli"; is_default = false };
    ]
  in
  let mk_acct ?(display_name = "") scope_id pids : Wire_runtime.account_usage =
    {
      scope = "provider:" ^ scope_id;
      scope_id;
      providers =
        List.map
          (fun id ->
            {
              Wire_runtime.id;
              display_name = if String.equal display_name "" then id else display_name;
            })
          pids;
      state = Wire_runtime.Account_not_reported_since_start;
      cost_state = Format_val.Unreported;
    }
  in
  let a_alice = mk_acct "claude_code_a1b2c3d4" [ "claude_code_a1b2c3d4" ] in
  let a_bob = mk_acct "claude_code_b2c3d4e5" [ "claude_code_b2c3d4e5" ] in
  let a_carol = mk_acct "claude_code_c3d4e5f6" [ "claude_code_c3d4e5f6" ] in
  let a_hash = mk_acct "claude_code_1c0558f0" [ "claude_code_1c0558f0" ] in
  let a_custom = mk_acct "custom_cli_9f8e7d6c" [ "custom_cli_9f8e7d6c" ] in
  let a_agy = mk_acct "antigravity_e5f60718" [ "antigravity_e5f60718" ] in
  let a_codex3 = mk_acct "codex_shared" [ "codex"; "codex_2"; "codex_3" ] in
  let a_glm = mk_acct "glm-coding" [ "glm-coding" ] in
  let a_kimi = mk_acct "kimi_coding" [ "kimi_coding" ] in
  let a_acme = mk_acct ~display_name:"Acme API" "acme_api" [ "acme_api" ] in
  let all_accounts =
    [ a_alice; a_bob; a_carol; a_hash; a_custom; a_agy; a_codex3; a_glm; a_kimi; a_acme ]
  in
  let lbl ?(lang = Say.Lang_ko) a =
    Wire_runtime.human_provider_label ~lang ~runtimes ~all_accounts a
  in
  Alcotest.(check string) "alice alias" "Claude Code (alice)" (lbl a_alice);
  Alcotest.(check string) "bob alias" "Claude Code (bob)" (lbl a_bob);
  Alcotest.(check string) "carol alias" "Claude Code (carol)" (lbl a_carol);
  Alcotest.(check string) "fallback short hash" "Claude Code #1c05" (lbl a_hash);
  Alcotest.(check string) "unknown hashed provider uses title case + short4" "Custom Cli #9f8e" (lbl a_custom);
  Alcotest.(check string) "antigravity stripped" "Antigravity CLI" (lbl a_agy);
  Alcotest.(check string) "codex 3 accounts ko" "Codex CLI (3계정)" (lbl ~lang:Say.Lang_ko a_codex3);
  Alcotest.(check string) "codex 3 accounts en" "Codex CLI (3 accounts)" (lbl ~lang:Say.Lang_en a_codex3);
  Alcotest.(check string) "glm-coding" "Z.AI Coding" (lbl a_glm);
  Alcotest.(check string) "kimi_coding" "Kimi Coding" (lbl a_kimi);
  Alcotest.(check string) "no redundant (#scope_id)" "Acme API" (lbl a_acme);
  Alcotest.(check string) "human_runtime_slot_label"
    "Claude Code (alice) · claude-opus-4-6"
    (Wire_runtime.human_runtime_slot_label ~runtimes "alice.opus");
  (* 5. Live 8935 dashboard/shell without tasks_done_24h + sparklines + 5 companies *)
  let live_shell =
    expect_ok "live 8935 shell without counts.tasks_done_24h"
      (Wire_fleet.decode_dashboard_shell ~observed_at:t0
         (parse_json
            {|{
              "counts": { "agents": 4, "tasks": 12, "keepers": 32, "total_runtimes": 10 },
              "groups": []
            }|}))
  in
  Alcotest.(check int) "shell.counts.tasks_done_24h defaults to 0" 0
    live_shell.counts.tasks_done_24h;
  Alcotest.(check (option int)) "scorecard tasks_done_24h unreported" None
    (Observed.to_option live_shell.scorecard_24h.tasks_done_24h);
  ignore
    (expect_err "negative counts.tasks_done_24h rejected"
       (Wire_fleet.decode_dashboard_shell ~observed_at:t0
          (parse_json
             {|{ "counts": { "agents": 1, "tasks": 1, "tasks_done_24h": -2, "keepers": 1, "total_runtimes": 1 } }|}))
      : string);
  let live_keeper_json =
    parse_json
      {|{
        "keepers": [
          {
            "name": "alpha-builder",
            "group": "Platform Core",
            "health": "working",
            "paused": false,
            "keepalive_running": true,
            "activation_mode": "autonomous",
            "runtime_id": "alice.opus",
            "meta": { "sandbox_profile": "microvm" },
            "candle_balance_milli": 5000,
            "runtime_lane_observation": { "turn": { "turn_count": 77 } },
            "recent_turns": {
              "known_since": 1795166000,
              "slots": [
                { "starts_at": 1795251600, "ok": 3, "rested": 0, "failed": 1,
                  "scheduled": 2, "reacted": 1, "chat": 1, "own": 0, "unknown": 0 },
                { "starts_at": 1795248000, "ok": 1, "rested": 0, "failed": 0,
                  "scheduled": 0, "reacted": 0, "chat": 0, "own": 1, "unknown": 0 }
              ]
            }
          }
        ],
        "candle": { "status": "ready", "issued_milli": "10000", "burned_milli": "2000", "circulating_milli": "8000" }
      }|}
  in
  let ks =
    (expect_ok "live keeper decode"
       (Wire_fleet.decode_keepers_roster ~observed_at:t0 live_keeper_json))
      .keepers
  in
  let k0 = List.hd ks in
  Alcotest.(check (option int)) "turn_count fallback from runtime_lane_observation"
    (Some 77) (Observed.to_option k0.total_turns);
  let extras =
    expect_ok "decode_keepers_roster_extras"
      (Wire_fleet.decode_keepers_roster_extras live_keeper_json)
  in
  Alcotest.(check bool) "sandbox_profile = microvm" true
    (List.assoc_opt "alpha-builder" extras.sandbox_profiles
     = Some Wire_fleet.Profile_microvm);
  (match List.assoc_opt "alpha-builder" extras.turn_pulses with
   | Some ({ Wire_fleet.slots = [ older; newer ]; known_since } as pulse) ->
       Alcotest.(check (float 0.5)) "pulse known_since" 1795166000.0 known_since;
       Alcotest.(check (list int)) "older slot causes: own"
         [ 0; 0; 0; 1; 0 ]
         [ older.scheduled; older.reacted; older.chat; older.own; older.unknown ];
       Alcotest.(check (list int)) "newer slot causes: scheduled, reacted, chat"
         [ 2; 1; 1; 0; 0 ]
         [ newer.scheduled; newer.reacted; newer.chat; newer.own; newer.unknown ];
       (* Issue #54536: 24h sparkline and turn sum anchor to now_unix, not newest_slot. *)
       let spark_at_newer =
         Wire_fleet.sparkline_24h_of_pulse ~now_unix:1795252000.0 pulse
       in
       Alcotest.(check int) "sparkline always spans 48 half-hour slots" 48
         (List.length spark_at_newer);
       let tail3 =
         List.filteri (fun i _ -> i >= 45) spark_at_newer
       in
       Alcotest.(check (list (float 0.01)))
         "at newer slot: last 3 slots are [1.0; 0.0; 4.0]"
         [ 1.0; 0.0; 4.0 ] tail3;
       Alcotest.(check int) "turns_24h_of_pulse counts both in-window slots" 5
         (Wire_fleet.turns_24h_of_pulse ~now_unix:1795252000.0 pulse);
       (* Two hours later: quiet trailing hours appear as 0.0s. *)
       let spark_2h_later =
         Wire_fleet.sparkline_24h_of_pulse ~now_unix:(1795251600.0 +. 7200.0) pulse
       in
       let tail7 = List.filteri (fun i _ -> i >= 41) spark_2h_later in
       Alcotest.(check (list (float 0.01)))
         "two quiet hours append 4 trailing zeros"
         [ 1.0; 0.0; 4.0; 0.0; 0.0; 0.0; 0.0 ] tail7;
       (* Two days later: old slots drop out completely -> 0 turns and 48 zeros. *)
       let now_2d_later = 1795251600.0 +. (48.0 *. 3600.0) in
       Alcotest.(check int) "turns_24h_of_pulse is 0 after 2 quiet days" 0
         (Wire_fleet.turns_24h_of_pulse ~now_unix:now_2d_later pulse);
       Alcotest.(check bool) "sparkline is all zeros after 2 quiet days" true
         (List.for_all (fun v -> Float.equal v 0.0)
            (Wire_fleet.sparkline_24h_of_pulse ~now_unix:now_2d_later pulse))
   | Some _ | None -> Alcotest.fail "expected alpha-builder's two pulse slots, oldest first");
  Alcotest.(check (option string)) "candle circulating fallback" (Some "8000")
    (match extras.candle_summary with
     | Some (Wire_fleet.Candle_ready c) -> Some c.circulating_milli
     | Some (Wire_fleet.Candle_off | Wire_fleet.Candle_disabled _) | None -> None);
  let enrichments, _ =
    expect_ok "decode_execution_keeper_enrichments"
      (Wire_fleet.decode_execution_keeper_enrichments
         (parse_json
            {|{ "keepers": [{ "name": "alpha-builder", "sandbox_profile": "remote_ssh" }] }|}))
  in
  Alcotest.(check bool) "execution enrichment sandbox_profile" true
    ((List.hd enrichments).sandbox_profile = Some Wire_fleet.Profile_remote_ssh);
  let companies =
    Wire_fleet.group_by_company ~sandbox_profiles:extras.sandbox_profiles
      ~keeper_costs_24h:[ ("alpha-builder", 0.35) ]
      ~now_unix:1795252000.0 ~turn_pulses:extras.turn_pulses
      ks
  in
  let cg = List.hd companies in
  Alcotest.(check string) "company = Platform Core" "Platform Core" cg.company;
  Alcotest.(check int) "company microvm_count = 1" 1 cg.microvm_count;
  Alcotest.(check int) "company turns_24h = 5" 5 cg.turns_24h;
  Alcotest.(check int) "company sparkline_24h has 48 slots" 48
    (List.length cg.sparkline_24h);
  let companies_2d_later =
    Wire_fleet.group_by_company ~sandbox_profiles:extras.sandbox_profiles
      ~keeper_costs_24h:[ ("alpha-builder", 0.35) ]
      ~now_unix:(1795251600.0 +. (48.0 *. 3600.0))
      ~turn_pulses:extras.turn_pulses
      ks
  in
  Alcotest.(check int) "company turns_24h drops to 0 after 2 quiet days" 0
    (List.hd companies_2d_later).turns_24h;
  Alcotest.(check (float 0.01)) "company cost_24h_usd = 0.35" 0.35 cg.cost_24h_usd;
  (* 6. Planning backlog, Board signal filter, workspace-memory fallback, Config KO/EN labels *)
  (match
     expect_ok "decode_planning_backlog_counts"
       (Wire_work.decode_planning_backlog_counts
          (parse_json
             {|{ "task_backlog": { "total": 20, "todo": 5, "claimed": 2, "in_progress": 3, "done": 9, "cancelled": 1 } }|}))
   with
  | Some backlog -> Alcotest.(check int) "backlog done = 9" 9 backlog.done_total
  | None -> Alcotest.fail "expected Some backlog counts");
  Alcotest.(check bool) "board_list_path includes exclude_system=true" true
    (let p = Wire_knowledge.board_list_path ~signal_only:true () in
     let needle = "exclude_system=true" in
     let plen = String.length p in
     let nlen = String.length needle in
     let rec find i =
       if i + nlen > plen then false
       else if String.equal (String.sub p i nlen) needle then true
       else find (i + 1)
     in
     find 0);
  let verify_feed =
    expect_ok "decode Verify: post without is_signal"
      (Wire_knowledge.decode_board_feed ~observed_at:t0
         (parse_json
            {|{ "posts": [{ "id": "p-v", "author": "masc-verifier", "title": "Verify: task-123", "body": "ok", "hearth": "verification", "post_kind": "automation", "created_at": 1795250000.0 }] }|}))
  in
  let verify_post = List.hd verify_feed.posts in
  Alcotest.(check bool) "Verify: post filtered as non-signal" false verify_post.is_signal;
  let wm_fallback =
    expect_ok "decode_workspace_memory_inventory_as_world_memory"
      (Wire_knowledge.decode_workspace_memory_inventory_as_world_memory
         (parse_json
            {|{ "status": "available", "claim_count": 42, "conflict_count": 3, "excluded_count": 1, "ordinary_absence": { "facts": 18, "status": "ok" } }|}))
  in
  Alcotest.(check int) "world_memory fallback claims_count" 42 wm_fallback.claims_count;
  Alcotest.(check int) "world_memory fallback facts_count" 18 wm_fallback.facts_count;
  Alcotest.(check int) "world_memory fallback conflicts_count" 3 wm_fallback.conflicts_count;
  let mk_cfg_field table key : Wire_config.schema_field =
    {
      table;
      key;
      full_key = table ^ "." ^ key;
      label = key;
      env = None;
      description = None;
      kind = Wire_config.Field_string;
      value = Wire_config.Val_string "v";
      default_value = None;
      provenance = Wire_config.Prov_project;
      reload_scope = Wire_config.Hot_reload;
      secret = false;
      writable = true;
    }
  in
  let f_auth_mode = mk_cfg_field "providers.claude.auth" "mode" in
  let f_max_ctx = mk_cfg_field "models.opus" "max_context" in
  Alcotest.(check string) "KO leaf label auth.mode" "인증 방식"
    (Wire_config.field_leaf_label ~lang:Say.Lang_ko f_auth_mode);
  Alcotest.(check string) "EN leaf label auth.mode" "Auth Mode"
    (Wire_config.field_leaf_label ~lang:Say.Lang_en f_auth_mode);
  Alcotest.(check string) "KO leaf label max_context" "최대 컨텍스트"
    (Wire_config.field_leaf_label ~lang:Say.Lang_ko f_max_ctx);
  (* #143 P1-3: quote-aware split_dotted_segments & P2-6 generic binding tags *)
  Alcotest.(check (list string)) "quote-aware split_dotted_segments"
    [ "models"; "gpt-5.6" ]
    (Wire_config.split_dotted_segments {|models."gpt-5.6"|});
  Alcotest.(check (list string)) "quote-aware quoted key segment"
    [ "providers"; "anthropic"; "headers"; "x-api.version" ]
    (Wire_config.split_dotted_segments {|providers.anthropic.headers."x-api.version"|});
  let generic_rt : Wire_runtime.runtime_option list =
    [
      {
        id = "alice.opus";
        provider_id = "claude_code_deadbeef";
        provider = "claude_code_deadbeef";
        model = Some "claude-opus-4-6";
        declared_reasoning_effort = None;
        transport = Some "cli";
        is_default = false;
      };
    ]
  in
  Alcotest.(check string) "generic binding derived from runtime prefix (no hardcoded hashes)"
    "Claude Code (alice)"
    (Wire_runtime.human_provider_id_label ~runtimes:generic_rt "claude_code_deadbeef");
  Alcotest.(check string) "without runtimes falls back to #short4 (no personal handle)"
    "Claude Code #1c05"
    (Wire_runtime.human_provider_id_label ~runtimes:[] "claude_code_1c0558f0");
  (* Round 5.5: per-model binding sub_group & localized binding labels *)
  let f_bind_sonnet = mk_cfg_field "openrouter.claude-sonnet-5-5" "max-context" in
  let f_bind_quoted = mk_cfg_field {|openrouter."gpt-5.6"|} "max-concurrent" in
  let f_prov_creds = mk_cfg_field "providers.openrouter.credentials" "api_key" in
  let f_model_set = mk_cfg_field "model_sets.fast" "members" in
  Alcotest.(check (option string)) "per-model binding sub_group"
    (Some "binding:claude-sonnet-5-5")
    (Wire_config.field_sub_group f_bind_sonnet);
  Alcotest.(check (option string)) "quote-aware per-model binding sub_group"
    (Some "binding:gpt-5.6")
    (Wire_config.field_sub_group f_bind_quoted);
  Alcotest.(check (option string)) "provider credentials sub_group preserved"
    (Some "credentials")
    (Wire_config.field_sub_group f_prov_creds);
  Alcotest.(check (option string)) "model_sets.* not tagged as binding"
    None
    (Wire_config.field_sub_group f_model_set);
  Alcotest.(check string) "KO per-model binding hairline label"
    "모델 바인딩 · claude-sonnet-5-5"
    (Wire_config.sub_group_label ~lang:Say.Lang_ko "binding:claude-sonnet-5-5");
  Alcotest.(check string) "EN per-model binding hairline label"
    "Model Binding · claude-sonnet-5-5"
    (Wire_config.sub_group_label ~lang:Say.Lang_en "binding:claude-sonnet-5-5");
  Alcotest.(check string) "KO max-concurrent leaf label" "최대 동시 실행"
    (Wire_config.field_leaf_label ~lang:Say.Lang_ko f_bind_quoted);
  Alcotest.(check string) "EN max-concurrent leaf label" "Max Concurrent"
    (Wire_config.field_leaf_label ~lang:Say.Lang_en f_bind_quoted)

let test_efficiency_null_cache_hit_pct_preserved () =
  let t0 = Clock.Mono.of_ns 5_000_000_000L in
  (* 1. Explicit cache_hit_pct: null with non-zero input_tokens + cache_read_tokens
        must stay Observed.Absent (NEVER recomputed from unpaired totals). *)
  let unpaired_json =
    parse_json
      {|{
        "schema": "masc.keeper-efficiency/v1",
        "month": "2026-10",
        "window_kind": "month_complete",
        "generated_at": 1795254000.0,
        "days_covered": 31,
        "fleet": {
          "turns_total": 2,
          "calls_per_turn": 1.0,
          "tool_s_per_turn": 0.5,
          "output_tokens_per_turn": 100.0,
          "input_tokens_per_turn": 5000.0,
          "cost_usd_per_turn": 0.10,
          "cache_hit_pct": null
        },
        "keepers": [
          {
            "keeper": "unpaired-alpha",
            "turns": 2,
            "input_tokens": 10000,
            "output_tokens": 200,
            "cache_read_tokens": 500,
            "cache_creation_tokens": null,
            "cache_hit_pct": null,
            "cost_usd": 0.20,
            "calls": 2,
            "failed": 0,
            "deferred": 0,
            "tool_ms": 1000.0
          }
        ]
      }|}
  in
  let eff =
    expect_ok "decode unpaired null efficiency"
      (Wire_runtime.decode_efficiency_month ~observed_at:t0 unpaired_json)
  in
  Alcotest.(check bool) "window_kind = Some Efficiency_month_complete" true
    (eff.window_kind = Some Wire_runtime.Efficiency_month_complete);
  Alcotest.(check bool) "fleet explicit null cache_hit_pct stays Absent" true
    (match eff.fleet.fleet_cache_hit_pct with
    | Observed.Absent -> true
    | Observed.Value _ | Observed.Unreported | Observed.Loading _ | Observed.Failed _ ->
        false);
  (match eff.keepers with
  | [ row ] ->
      Alcotest.(check bool) "keeper explicit null cache_hit_pct stays Absent" true
        (match row.cache_hit_pct with
        | Observed.Absent -> true
        | Observed.Value _ | Observed.Unreported | Observed.Loading _ | Observed.Failed _ ->
            false)
  | _ -> Alcotest.fail "expected 1 keeper efficiency row");
  (* 2. Omitted cache_hit_pct key (legacy server) still falls back to computed ratio. *)
  let legacy_json =
    parse_json
      {|{
        "schema": "masc.keeper-efficiency/v1",
        "month": "2026-11",
        "window_kind": "month_mtd",
        "generated_at": 1795254000.0,
        "days_covered": 22,
        "fleet": {
          "turns_total": 1,
          "calls_per_turn": 1.0,
          "tool_s_per_turn": 0.5,
          "output_tokens_per_turn": 100.0,
          "input_tokens_per_turn": 1000.0,
          "cost_usd_per_turn": 0.10
        },
        "keepers": [
          {
            "keeper": "legacy-beta",
            "turns": 1,
            "input_tokens": 1000,
            "output_tokens": 100,
            "cache_read_tokens": 400,
            "cache_creation_tokens": 0,
            "cost_usd": 0.10,
            "calls": 1,
            "failed": 0,
            "deferred": 0,
            "tool_ms": 500.0
          }
        ]
      }|}
  in
  let legacy_eff =
    expect_ok "decode legacy missing cache_hit_pct"
      (Wire_runtime.decode_efficiency_month ~observed_at:t0 legacy_json)
  in
  Alcotest.(check bool) "window_kind = Some Efficiency_month_mtd" true
    (legacy_eff.window_kind = Some Wire_runtime.Efficiency_month_mtd);
  Alcotest.(check (option (float 0.01))) "legacy missing fleet cache_hit_pct computes 40.0"
    (Some 40.0) (Observed.to_option legacy_eff.fleet.fleet_cache_hit_pct);
  (match legacy_eff.keepers with
  | [ row ] ->
      Alcotest.(check (option (float 0.01))) "legacy missing keeper cache_hit_pct computes 40.0"
        (Some 40.0) (Observed.to_option row.cache_hit_pct)
  | _ -> Alcotest.fail "expected 1 legacy keeper efficiency row");
  (* 3. Unknown window_kind rejected strictly *)
  let bad_window_kind =
    parse_json
      {|{
        "schema": "masc.keeper-efficiency/v1",
        "month": "2026-11",
        "window_kind": "quarter_to_date",
        "generated_at": 1795254000.0,
        "days_covered": 22,
        "fleet": {
          "turns_total": 0, "calls_per_turn": 0.0, "tool_s_per_turn": 0.0,
          "output_tokens_per_turn": 0.0, "input_tokens_per_turn": 0.0,
          "cost_usd_per_turn": 0.0, "cache_hit_pct": null
        },
        "keepers": []
      }|}
  in
  ignore
    (expect_err "unknown efficiency window_kind rejected"
       (Wire_runtime.decode_efficiency_month ~observed_at:t0 bad_window_kind)
      : string)

let test_p1_7_wire_fleet_offline_vs_failing_ssot () =
  let mk ~name ~health ~paused ~keepalive_running : Wire_fleet.keeper_summary =
    {
      name;
      group = Some "MASC Core";
      company = "MASC Core";
      health;
      paused;
      keepalive_running;
      activation_mode = Wire_fleet.Activation_autonomous;
      runtime_id = "sonnet";
      model_id = Some "claude-sonnet-4";
      current_task_id = None;
      context = Observed.unreported;
      total_turns = Observed.unreported;
      last_turn_at_unix = None;
      active_turn = None;
    }
  in
  let keepers =
    [
      mk ~name:"k-working" ~health:Wire_fleet.Keeper_working ~paused:false
        ~keepalive_running:true;
      mk ~name:"k-healthy" ~health:Wire_fleet.Keeper_healthy ~paused:false
        ~keepalive_running:true;
      mk ~name:"k-degraded" ~health:Wire_fleet.Keeper_degraded ~paused:false
        ~keepalive_running:true;
      (* Live 8935 bug: failing keeper with keepalive_running=true MUST NOT inflate running_count *)
      mk ~name:"k-failing" ~health:Wire_fleet.Keeper_failing ~paused:false
        ~keepalive_running:true;
      (* Ordinary stopped/offline keepers MUST NOT inflate failing_count or running_count *)
      mk ~name:"k-offline-1" ~health:Wire_fleet.Keeper_offline ~paused:false
        ~keepalive_running:false;
      mk ~name:"k-offline-2" ~health:Wire_fleet.Keeper_offline ~paused:false
        ~keepalive_running:true;
      mk ~name:"k-paused" ~health:Wire_fleet.Keeper_paused ~paused:true
        ~keepalive_running:false;
      (* Verifier #243 finding 4: paused=true must match Fleet_store.fleet_health_counts precedence
         without double-counting into working_count or failing/offline into paused_count. *)
      mk ~name:"k-work-paused" ~health:Wire_fleet.Keeper_working ~paused:true
        ~keepalive_running:true;
      mk ~name:"k-fail-paused" ~health:Wire_fleet.Keeper_failing ~paused:true
        ~keepalive_running:false;
      mk ~name:"k-off-paused" ~health:Wire_fleet.Keeper_offline ~paused:true
        ~keepalive_running:false;
    ]
  in
  let groups = Wire_fleet.group_by_company keepers in
  Alcotest.(check int) "1 company group" 1 (List.length groups);
  let cg = List.hd groups in
  Alcotest.(check int) "running_count excludes failing/offline/paused" 3
    cg.running_count;
  Alcotest.(check int) "failing_count counts ONLY Keeper_failing (including paused=true)" 2
    cg.failing_count;
  Alcotest.(check int) "paused_count excludes failing & offline (no double count)" 2
    cg.paused_count;
  Alcotest.(check int) "working_count excludes paused working keeper (<= running_count)" 1
    cg.working_count

let test_tui_memory_os_and_runtime_setup_codecs () =
  (* 1. Writer health canonical stop + snapshot_file + available_acts *)
  let diff_json =
    parse_json
      {|{
        "schema_version": 1, "instance_id": "srv-1", "generated_at_unix": 1795252092.0,
        "data": {
          "scope": { "kind": "keeper", "keeper": "alpha" },
          "range": { "window": "24h", "from_rev": null, "to_rev": 1, "from_unix": 1795165692.0, "to_unix": 1795252092.0 },
          "counts": {
            "total_facts_now": 2, "added": 0, "updated": 0, "retracted": 0,
            "invalidated": 0, "journal_failures_in_window": 0,
            "journal_quarantines_in_window": 0, "undecodable_journal_lines": 0
          },
          "retrieval_heat": { "hot": 0, "warm": 0, "cold": 0, "never_retrieved": 2, "total_events": 0, "unreadable_event_lines": 0 },
          "revisions": [], "added": [], "updated": [], "retracted": [], "invalidated": [],
          "writer_status": {
            "kind": "writer",
            "row": {
              "state": "stopped",
              "stop": "store_stopped_log_unreadable",
              "alarms": ["E1"],
              "available_acts": ["adopt", "restart_reading"],
              "snapshot_file": { "sha": "abcdef0123456789", "bytes": 512 }
            }
          }
        }
      }|}
  in
  let decoded_diff = expect_ok "memory diff with canonical stop & snapshot_file"
      (Wire_knowledge.decode_memory_diff diff_json) in
  (match decoded_diff.body with
  | Wire_knowledge.Keeper_diff
      {
        writer_status =
          Some
            (Wire_knowledge.Keeper_writer_active
               { state; available_act_tokens; snapshot_file });
        _;
      } ->
      Alcotest.(check bool) "state decodes canonical stop field" true
        (state = Wire_knowledge.Writer_stopped "store_stopped_log_unreadable");
      Alcotest.(check (list string)) "available_acts decoded"
        [ "adopt"; "restart_reading" ] available_act_tokens;
      Alcotest.(check bool) "snapshot_file present decoded" true
        (snapshot_file = Some (Wire_knowledge.Snapshot_file_present { sha = "abcdef0123456789"; bytes = 512 }))
  | _ -> Alcotest.fail "expected Keeper_diff with Keeper_writer_active");
  (* 2. decode_memory_os_internals *)
  let internals_json =
    parse_json
      {|{
        "keeper": "alpha",
        "compaction": {
          "present": true, "epoch_count": 2, "archived_turns_count": 14,
          "anchor_bytes": 2048, "latest_epoch_id": 2,
          "covers_through_turn": "turn-14", "archived_epochs_through": 1,
          "observations_count": 9
        },
        "canonical_turns": {
          "present": true, "turn_count": 18, "latest_turn_id": "turn-18",
          "latest_runtime_kind": "acp_cli", "latest_runtime_id": "vibe_acp.devstral-2",
          "compaction_watermark_seq": 14, "compaction_watermark_epoch": 2,
          "history_resets_count": 0
        },
        "memory_digest": {
          "present": true, "revision": 7, "digest_sha256": "deadbeef12345678",
          "bytes": 1024, "fact_count": 11, "derived_count": 2
        },
        "librarian_molt": {
          "writer_kind": "writer", "writer_state": "idle",
          "pending_molt": { "kind": "structural", "epoch_id": 2 },
          "pending_molt_categories": ["fact", "lesson"],
          "available_acts": ["resume"]
        }
      }|}
  in
  let mi = expect_ok "memory_os_internals"
      (Wire_knowledge.decode_memory_os_internals internals_json) in
  Alcotest.(check string) "internals keeper" "alpha" mi.keeper;
  Alcotest.(check int) "compaction epochs" 2 mi.compaction.epoch_count;
  Alcotest.(check (option int)) "typed observation count" (Some 9) mi.compaction.observations_count;
  Alcotest.(check (option string)) "canonical runtime_kind" (Some "acp_cli")
    mi.canonical_turns.latest_runtime_kind;
  Alcotest.(check (option int)) "digest revision" (Some 7) mi.memory_digest.revision;
  Alcotest.(check (option string)) "pending molt kind" (Some "structural")
    mi.librarian_molt.pending_molt_kind;
  Alcotest.(check (list string)) "pending molt categories" [ "fact"; "lesson" ]
    mi.librarian_molt.pending_molt_categories;
  (* 3. Wire_runtime provider_id + declared_reasoning_effort + @effort label *)
  let resolved_json =
    parse_json
      {|{
        "generated_at_iso": "2026-11-22T12:00:00Z",
        "source": "/api/v1/runtime/resolved",
        "config_path": null,
        "default_route": "primary",
        "lanes": [{ "id": "primary", "declared": true, "runtime_ids": ["ollama_cloud.qwen3-high"] }],
        "runtimes": [{
          "id": "ollama_cloud.qwen3-high",
          "provider_id": "ollama_cloud",
          "provider": "Ollama Cloud",
          "model": "qwen3-coder",
          "declared_reasoning_effort": "high",
          "transport": "http",
          "is_default": true
        }]
      }|}
  in
  let res = expect_ok "runtime_resolved with effort & provider_id"
      (Wire_runtime.decode_runtime_resolved resolved_json) in
  let rt0 = List.hd res.runtimes in
  Alcotest.(check string) "provider_id preserved" "ollama_cloud" rt0.provider_id;
  Alcotest.(check (option string)) "declared_reasoning_effort decoded"
    (Some "high") rt0.declared_reasoning_effort;
  let slot_lbl = Wire_runtime.human_runtime_slot_label ~runtimes:res.runtimes rt0.id in
  Alcotest.(check bool) "human_runtime_slot_label appends @high" true
    (String.length slot_lbl >= 5
     && String.sub slot_lbl (String.length slot_lbl - 5) 5 = "@high");
  (* 4. Wire_config fixed capability & new TOML key labels *)
  let mk_cfg_field k : Wire_config.schema_field =
    {
      table = "models.sonnet";
      key = k;
      full_key = "models.sonnet." ^ k;
      label = k;
      env = None;
      description = None;
      kind = Wire_config.Field_bool;
      value = Wire_config.Val_null;
      default_value = None;
      provenance = Wire_config.Prov_default;
      reload_scope = Wire_config.Hot_reload;
      secret = false;
      writable = true;
    }
  in
  List.iter
    (fun k ->
      let fld = mk_cfg_field k in
      let ko_lbl = Wire_config.field_leaf_label ~lang:Say.Lang_ko fld in
      let en_lbl = Wire_config.field_leaf_label ~lang:Say.Lang_en fld in
      Alcotest.(check bool) ("field_leaf_label has KO/EN dictionary hit for " ^ k) true
        (not (String.equal ko_lbl en_lbl) && not (String.equal en_lbl k)))
    [
      "supports-image-input";
      "supports-prompt-caching";
      "tools-support";
      "cache-retention";
      "explicit-context-cache-ttl-s";
      "store";
      "efforts";
    ];
  (* 5. Runtime config raw meta, assignment CAS encoder, setup inventory & keyring_host receipt *)
  let raw_json =
    parse_json
      {|{
        "source_revision": "sha-rev-99",
        "source_text": "[runtime]\ndefault = \"primary\"\n[runtime.assignments]\nalpha = \"ollama_cloud.qwen3-high\"\n\"beta-1\" = \"primary\"\n"
      }|}
  in
  let meta = expect_ok "runtime_config_raw_meta"
      (Wire_runtime.decode_runtime_config_raw_meta raw_json) in
  Alcotest.(check string) "raw source_revision" "sha-rev-99" meta.source_revision;
  Alcotest.(check (option string)) "assignment alpha"
    (Some "ollama_cloud.qwen3-high") (List.assoc_opt "alpha" meta.assignments);
  Alcotest.(check (option string)) "assignment beta-1"
    (Some "primary") (List.assoc_opt "beta-1" meta.assignments);
  let assign_body =
    Wire_runtime.encode_runtime_assignment ~keeper_name:"alpha"
      ~runtime_id:(Some "primary") ~source_revision:(Some "sha-rev-99")
      ~previous_runtime_id:(Some "ollama_cloud.qwen3-high") ()
  in
  Alcotest.(check bool) "assignment CAS body carries expected_assignment_revision" true
    (Yojson.Safe.Util.member "expected_assignment_revision" assign_body <> `Null);
  let inv_json =
    parse_json
      {|{
        "default_runtime_id": "primary",
        "integrations": [{
          "id": "vibe_acp",
          "display_name": "Mistral Vibe",
          "protocol": "acp",
          "origin": "configured",
          "setup_support": "existing_binding",
          "enabled": true,
          "credential_kind": "none",
          "configured_runtime_ids": ["vibe_acp.devstral-2"]
        }]
      }|}
  in
  let inv = expect_ok "setup_inventory" (Wire_runtime.decode_setup_inventory inv_json) in
  Alcotest.(check int) "1 setup integration" 1 (List.length inv.integrations);
  Alcotest.(check string) "vibe_acp setup_support" "existing_binding"
    (List.hd inv.integrations).setup_support;
  let receipt_json =
    parse_json
      {|{
        "login_id": "login-vibe-1",
        "integration_id": "vibe_acp",
        "account": "keyring_host",
        "account_ref": null,
        "authentication": "login_completed"
      }|}
  in
  let recp = expect_ok "setup_login_receipt keyring_host SSE"
      (Wire_runtime.decode_setup_login_receipt receipt_json) in
  Alcotest.(check string) "inferred status complete" "complete" recp.status;
  Alcotest.(check (option string)) "account keyring_host" (Some "keyring_host") recp.account;
  Alcotest.(check (option string)) "account_ref None" None recp.account_ref

let test_chat_queue_pages () =
  let page = parse_json
      {|{"state":"Queued","operations":[{"operation_id":"op-x","sequence":"101","state":"Queued","input":{"message":"hello"}}]}|} in
  let rows = expect_ok "server queue after sequence" (Wire_fleet.decode_chat_queue ~after:(Some 100L) page) in
  Alcotest.(check (list string)) "server ids" ["op-x"]
    (List.map (fun (op : Wire_fleet.chat_operation) -> Keeper_chat_operation.Operation_id.to_string op.id) rows);
  Alcotest.(check bool) "a repeated cursor cannot advance a read" true
    (Result.is_error (Wire_fleet.decode_chat_queue ~after:(Some 101L) page));
  Alcotest.(check bool) "incomplete provenance is rejected" true
    (Result.is_error (Wire_fleet.decode_chat_history (parse_json
      {|[{"id":"row","role":"user","content":"hi","ts":42,"delivery_key":{"kind":"operation","operation_id":"op-x"}}]|})))

let test_agui_chat_stream_and_history_provenance () =
  (* BUG-1: Real server AG-UI SSE frames *)
  let accepted_running =
    expect_ok "CUSTOM KEEPER_CHAT_OPERATION_ACCEPTED (Running + interactive)"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{
              "type": "CUSTOM",
              "threadId": "default",
              "timestamp": 1795252000.0,
              "name": "KEEPER_CHAT_OPERATION_ACCEPTED",
              "value": {
                "operation_id": "tui-99-1",
                "state": "Running",
                "queued_count": 0,
                "interactive": {
                  "outcome": "applied",
                  "chat_control_token": "ctrl-tok-77",
                  "signalled": true,
                  "resumed": false,
                  "interrupt_error": null,
                  "interrupt_error_code": null,
                  "interrupt_incident_id": null
                }
              }
            }|}))
  in
  (match accepted_running with
  | Wire_fleet.Chunk_accepted
      {
        operation_id = "tui-99-1";
        queued_count = 0;
        state = Keeper_chat_operation.State_name.Running;
        interactive_outcome = Some Wire_fleet.Interactive_applied;
        control_token = Some "ctrl-tok-77";
      } ->
      ()
  | _ -> Alcotest.fail "unexpected Chunk_accepted decode");
  let accepted_queued =
    expect_ok "CUSTOM KEEPER_CHAT_OPERATION_ACCEPTED (Queued)"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{
              "type": "CUSTOM",
              "threadId": "default",
              "timestamp": 1795252000.5,
              "name": "KEEPER_CHAT_OPERATION_ACCEPTED",
              "value": {
                "operation_id": "tui-99-2",
                "state": "Queued",
                "queued_count": 1
              }
            }|}))
  in
  (match accepted_queued with
  | Wire_fleet.Chunk_accepted
      {
        operation_id = "tui-99-2";
        queued_count = 1;
        state = Keeper_chat_operation.State_name.Queued;
        interactive_outcome = None;
        control_token = None;
      } ->
      ()
  | _ -> Alcotest.fail "unexpected queued Chunk_accepted decode");
  let run_started =
    expect_ok "RUN_STARTED strips keeper-operation-run- prefix"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{
              "type": "RUN_STARTED",
              "threadId": "keeper:alpha-leader",
              "timestamp": 1795252001.0,
              "runId": "keeper-operation-run-tui-99-1"
            }|}))
  in
  (match run_started with
  | Wire_fleet.Chunk_run_started { operation_id = Some "tui-99-1" } -> ()
  | _ -> Alcotest.fail "expected Chunk_run_started with stripped operation_id");
  (* Finding #5: unprefixed arbitrary runId must NOT be treated as operation_id *)
  let run_started_unprefixed =
    expect_ok "RUN_STARTED with unprefixed runId yields operation_id=None"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{
              "type": "RUN_STARTED",
              "threadId": "keeper:alpha-leader",
              "timestamp": 1795252001.0,
              "runId": "arbitrary-run-42"
            }|}))
  in
  (match run_started_unprefixed with
  | Wire_fleet.Chunk_run_started { operation_id = None } -> ()
  | _ -> Alcotest.fail "expected operation_id=None for unprefixed runId");
  let text_delta =
    expect_ok "TEXT_MESSAGE_CONTENT without operation_id"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{
              "type": "TEXT_MESSAGE_CONTENT",
              "threadId": "keeper:alpha-leader",
              "timestamp": 1795252002.0,
              "runId": "keeper-operation-run-tui-99-1",
              "messageId": "msg-a",
              "delta": "안녕하세요"
            }|}))
  in
  (match text_delta with
  | Wire_fleet.Chunk_text_delta
      {
        operation_id = Some "tui-99-1";
        delta = "안녕하세요";
        owner = Wire_chat_journal.Unobserved_scope None;
      } ->
      ()
  | _ -> Alcotest.fail "expected Chunk_text_delta");
  let text_delta_no_run =
    expect_ok "TEXT_MESSAGE_CONTENT without runId or operation_id"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{"type":"TEXT_MESSAGE_CONTENT","threadId":"t","timestamp":1.0,"delta":"!"}|}))
  in
  (match text_delta_no_run with
  | Wire_fleet.Chunk_text_delta
      {
        operation_id = None;
        delta = "!";
        owner = Wire_chat_journal.Unobserved_scope None;
      } ->
      ()
  | _ -> Alcotest.fail "expected Chunk_text_delta with None operation_id");
  (* Issue #54530: runtime attempt boundary & textResponse / textStreamScope *)
  let attempt_started =
    expect_ok "CUSTOM KEEPER_RUNTIME_ATTEMPT_STARTED decodes as Chunk_runtime_attempt_started"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{
              "type": "CUSTOM",
              "threadId": "keeper:alpha-leader",
              "timestamp": 1795252002.1,
              "runId": "keeper-operation-run-tui-99-1",
              "name": "KEEPER_RUNTIME_ATTEMPT_STARTED",
              "value": { "runtime_id": "rt-2", "attempt_index": 2 }
            }|}))
  in
  (match attempt_started with
  | Wire_fleet.Chunk_runtime_attempt_started
      {
        operation_id = Some "tui-99-1";
        runtime_id = Some "rt-2";
        attempt_index = Some 2;
      } ->
      ()
  | _ -> Alcotest.fail "expected Chunk_runtime_attempt_started with runtime_id & attempt_index");
  let text_delta_owned =
    expect_ok "TEXT_MESSAGE_CONTENT decodes textResponse"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{
              "type": "TEXT_MESSAGE_CONTENT",
              "threadId": "keeper:alpha-leader",
              "timestamp": 1795252002.2,
              "runId": "keeper-operation-run-tui-99-1",
              "delta": "attempt 2",
              "textResponse": { "content_generation": 2, "stream_scope": 1 }
            }|}))
  in
  (match text_delta_owned with
  | Wire_fleet.Chunk_text_delta
      {
        operation_id = Some "tui-99-1";
        delta = "attempt 2";
        owner =
          Wire_chat_journal.Observed_response
            { content_generation = 2; stream_scope = 1 };
      } ->
      ()
  | _ -> Alcotest.fail "expected Observed_response on TEXT_MESSAGE_CONTENT");
  let text_delta_scoped =
    expect_ok "TEXT_MESSAGE_CONTENT decodes textStreamScope"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{
              "type": "TEXT_MESSAGE_CONTENT",
              "threadId": "keeper:alpha-leader",
              "timestamp": 1795252002.3,
              "delta": "scoped",
              "textStreamScope": 4
            }|}))
  in
  (match text_delta_scoped with
  | Wire_fleet.Chunk_text_delta
      {
        operation_id = None;
        delta = "scoped";
        owner = Wire_chat_journal.Unobserved_scope (Some 4);
      } ->
      ()
  | _ -> Alcotest.fail "expected Unobserved_scope (Some 4) on TEXT_MESSAGE_CONTENT");
  ignore
    (expect_err "TEXT_MESSAGE_CONTENT rejects conflicting textResponse + textStreamScope"
       (Wire_fleet.decode_chat_stream_chunk
          (parse_json
             {|{
               "type": "TEXT_MESSAGE_CONTENT",
               "threadId": "t",
               "timestamp": 1.0,
               "delta": "bad",
               "textResponse": { "content_generation": 1, "stream_scope": 0 },
               "textStreamScope": 1
             }|})));
  let think_delta =
    expect_ok "CUSTOM KEEPER_THINKING_DELTA"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{
              "type": "CUSTOM",
              "threadId": "keeper:alpha-leader",
              "timestamp": 1795252001.2,
              "runId": "keeper-operation-run-tui-99-1",
              "name": "KEEPER_THINKING_DELTA",
              "value": { "index": 0, "delta": "checking logs" }
            }|}))
  in
  (match think_delta with
  | Wire_fleet.Chunk_thinking_delta { operation_id = Some "tui-99-1"; delta = "checking logs"; owner = None }
    ->
      ()
  | _ -> Alcotest.fail "expected Chunk_thinking_delta");
  let think_snap =
    expect_ok "CUSTOM KEEPER_THINKING_SNAPSHOT"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{
              "type": "CUSTOM",
              "threadId": "keeper:alpha-leader",
              "timestamp": 1795252001.3,
              "name": "KEEPER_THINKING_SNAPSHOT",
              "value": { "index": 0, "snapshot": "full thought" }
            }|}))
  in
  (match think_snap with
  | Wire_fleet.Chunk_thinking_snapshot { snapshot = "full thought"; _ } -> ()
  | _ -> Alcotest.fail "expected Chunk_thinking_snapshot");
  (* TOOL_CALL_START / TOOL_CALL_ARGS / TOOL_CALL_END without toolCallId correlate by scope+block *)
  let tc_start =
    expect_ok "TOOL_CALL_START without toolCallId"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{
              "type": "TOOL_CALL_START",
              "threadId": "keeper:alpha-leader",
              "timestamp": 1795252001.4,
              "toolCallName": "masc_read_file",
              "toolStreamScope": 2,
              "toolCallBlockIndex": 1
            }|}))
  in
  (match tc_start with
  | Wire_fleet.Chunk_tool_start
      { tool_use_id = "scope-2-block-1"; tool_name = "masc_read_file"; _ } ->
      ()
  | _ -> Alcotest.fail "expected Chunk_tool_start with scope-2-block-1");
  let tc_args =
    expect_ok "TOOL_CALL_ARGS"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{
              "type": "TOOL_CALL_ARGS",
              "threadId": "keeper:alpha-leader",
              "timestamp": 1795252001.5,
              "toolStreamScope": 2,
              "toolCallBlockIndex": 1,
              "delta": "{\"path\":\"README.md\"}"
            }|}))
  in
  (match tc_args with
  | Wire_fleet.Chunk_tool_args
      { tool_use_id = "scope-2-block-1"; delta = Some "{\"path\":\"README.md\"}"; _ }
    ->
      ()
  | _ -> Alcotest.fail "expected Chunk_tool_args");
  let tc_end =
    expect_ok "TOOL_CALL_END closes arguments before result settlement"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{
              "type": "TOOL_CALL_END",
              "threadId": "keeper:alpha-leader",
              "timestamp": 1795252001.6,
              "toolStreamScope": 2,
              "toolCallBlockIndex": 1
            }|}))
  in
  (match tc_end with
  | Wire_fleet.Chunk_tool_block_end { tool_use_id = "scope-2-block-1"; _ } -> ()
  | _ -> Alcotest.fail "argument end must leave the tool unsettled");
  let tool_res =
    expect_ok "CUSTOM KEEPER_TOOL_RESULT_READY"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{
              "type": "CUSTOM",
              "threadId": "keeper:alpha-leader",
              "timestamp": 1795252001.7,
              "name": "KEEPER_TOOL_RESULT_READY",
              "value": { "toolStreamScope": 2, "toolCallBlockIndex": 1, "executionId": "ex-1" }
            }|}))
  in
  (match tool_res with
  | Wire_fleet.Chunk_tool_end { tool_use_id = "scope-2-block-1"; ok = None; _ } ->
      ()
  | _ -> Alcotest.fail "expected Chunk_tool_end from KEEPER_TOOL_RESULT_READY");
  let native_start =
    expect_ok "CUSTOM KEEPER_NATIVE_TOOL_START"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{
              "type": "CUSTOM",
              "threadId": "keeper:alpha-leader",
              "timestamp": 1795252001.8,
              "name": "KEEPER_NATIVE_TOOL_START",
              "value": { "toolCallId": "nt-1", "toolCallName": "Bash", "toolStreamScope": 1, "toolCallBlockIndex": 0 }
            }|}))
  in
  let native_occurrence =
    match native_start with
    | Wire_fleet.Chunk_tool_start
        { tool_use_id; tool_name = "Bash"; stream_scope = Some 1; _ } ->
        tool_use_id
    | _ -> Alcotest.fail "expected scoped Chunk_tool_start from KEEPER_NATIVE_TOOL_START"
  in
  Alcotest.(check string) "native tool uses the stream occurrence when a provider ID is also present"
    "scope-1-block-0" native_occurrence;
  let native_end =
    expect_ok "CUSTOM KEEPER_NATIVE_TOOL_END error_reported -> ok=Some false"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{
              "type": "CUSTOM",
              "threadId": "keeper:alpha-leader",
              "timestamp": 1795252001.9,
              "name": "KEEPER_NATIVE_TOOL_END",
              "value": {
                "toolCallId": "nt-1",
                "toolCallName": "Bash",
                "toolStreamScope": 1,
                "toolCallBlockIndex": 0,
                "completion": { "kind": "error_reported", "exit_code": 1 }
              }
            }|}))
  in
  (match native_end with
  | Wire_fleet.Chunk_tool_end
      { tool_use_id; tool_name = Some "Bash"; ok = Some false; _ } ->
      Alcotest.(check string) "native tool completion settles its original occurrence"
        native_occurrence tool_use_id
  | _ -> Alcotest.fail "expected native Chunk_tool_end with ok=Some false");
  let provider_only =
    expect_ok "native tool without occurrence coordinates"
      (Wire_fleet.decode_chat_stream_chunk (parse_json
         {|{"type":"CUSTOM","name":"KEEPER_NATIVE_TOOL_START",
            "value":{"toolCallId":"nt-1","toolCallName":"Bash"}}|}))
  in
  (match provider_only with
  | Wire_fleet.Chunk_tool_start { tool_use_id; stream_scope = None; _ } ->
      Alcotest.(check string) "provider ID identifies an unscoped native tool" "nt-1" tool_use_id
  | _ -> Alcotest.fail "expected unscoped native Chunk_tool_start");
  let reply_details =
    expect_ok "CUSTOM KEEPER_REPLY_DETAILS"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{
              "type": "CUSTOM",
              "threadId": "keeper:alpha-leader",
              "timestamp": 1795252002.5,
              "runId": "keeper-operation-run-tui-99-1",
              "name": "KEEPER_REPLY_DETAILS",
              "value": { "reply": "안녕하세요!", "turn_outcome": "completed", "turn_ref": "trace-1#5" }
            }|}))
  in
  (match reply_details with
  | Wire_fleet.Chunk_reply_details
      {
        operation_id = Some "tui-99-1";
        reply = "안녕하세요!";
        turn_outcome = Some "completed";
        turn_ref = Some "trace-1#5";
      } ->
      ()
  | _ -> Alcotest.fail "expected Chunk_reply_details");
  let run_fin =
    expect_ok "RUN_FINISHED without operation_id/turn_ref/reply"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{
              "type": "RUN_FINISHED",
              "threadId": "keeper:alpha-leader",
              "timestamp": 1795252003.0,
              "runId": "keeper-operation-run-tui-99-1"
            }|}))
  in
  (match run_fin with
  | Wire_fleet.Chunk_turn_done
      { operation_id = Some "tui-99-1"; turn_ref = None; reply = None } ->
      ()
  | _ -> Alcotest.fail "expected Chunk_turn_done from RUN_FINISHED");
  let run_err =
    expect_ok "RUN_ERROR"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{
              "type": "RUN_ERROR",
              "threadId": "keeper:alpha-leader",
              "timestamp": 1795252004.0,
              "runId": "keeper-operation-run-tui-99-1",
              "message": "provider unavailable",
              "code": "turn_failed"
            }|}))
  in
  (match run_err with
  | Wire_fleet.Chunk_error
      {
        operation_id = Some "tui-99-1";
        code = Some "turn_failed";
        message = "provider unavailable";
      } ->
      ()
  | _ -> Alcotest.fail "expected Chunk_error");
  (* Known non-visual frames decode to Chunk_ignored; unknown frames return Error *)
  Alcotest.(check bool) "TEXT_MESSAGE_START -> Chunk_ignored" true
    (expect_ok "text start"
       (Wire_fleet.decode_chat_stream_chunk
          (parse_json {|{"type":"TEXT_MESSAGE_START","threadId":"t","timestamp":1.0,"messageId":"m1","role":"assistant"}|}))
    = Wire_fleet.Chunk_ignored);
  Alcotest.(check bool) "KEEPER_STREAM_PING -> Chunk_ignored" true
    (expect_ok "ping"
       (Wire_fleet.decode_chat_stream_chunk
          (parse_json {|{"type":"CUSTOM","threadId":"t","timestamp":1.0,"name":"KEEPER_STREAM_PING","value":null}|}))
    = Wire_fleet.Chunk_ignored);
  ignore
    (expect_err "unknown CUSTOM rejected"
       (Wire_fleet.decode_chat_stream_chunk
          (parse_json {|{"type":"CUSTOM","threadId":"t","timestamp":1.0,"name":"MYSTERY_FRAME","value":{}}|}))
      : string);
  (* BUG-2 & BUG-7: /chat/history/page with role=request_failure, delivery_key, transcript_slot, failure_kind *)
  let page =
    expect_ok "history page with request_failure & provenance"
      (Wire_fleet.decode_chat_history_page
         (parse_json
            {|{
              "messages": [
                {
                  "id": "msg-100-1",
                  "role": "user",
                  "speaker_authority":"owner",
                  "content": "음",
                  "ts": 1795252000.0,
                  "delivery_key": { "kind": "operation", "operation_id": "tui-99-1" },
                  "transcript_slot": { "kind": "accepted_user" }
                },
                {
                  "id": "msg-100-2",
                  "role": "request_failure",
                  "content": "provider failed",
                  "ts": 1795252005.0,
                  "failure_kind": "turn_exception",
                  "delivery_key": { "kind": "operation", "operation_id": "tui-99-1" },
                  "transcript_slot": { "kind": "settled_failure" }
                }
              ],
              "has_more": false,
              "next_cursor": null
            }|}))
  in
  Alcotest.(check int) "2 history rows decoded" 2 (List.length page.messages);
  let u_msg = List.nth page.messages 0 in
  let f_msg = List.nth page.messages 1 in
  Alcotest.(check (option string)) "user operation_id" (Some "tui-99-1") (Wire_fleet.accepted_input_operation u_msg);
  Alcotest.(check bool) "failure role is Role_request_failure" true
    (f_msg.role = Wire_fleet.Role_request_failure);
  Alcotest.(check (option string)) "failure operation_id" (Some "tui-99-1") (Wire_fleet.terminal_operation f_msg);
  Alcotest.(check (option string)) "failure_kind" (Some "turn_exception") f_msg.failure_kind;
  (* Turn interrupt response decoder *)
  let int_resp =
    expect_ok "turn interrupt response"
      (Wire_fleet.decode_turn_interrupt_response
         (parse_json
            {|{"request_id":"tui-99-1","chat_control_token":"ctrl-88","signalled":true}|}))
  in
  Alcotest.(check bool) "interrupt signalled" true int_resp.signalled;
  Alcotest.(check (option string)) "interrupt chat_control_token"
    (Some "ctrl-88") int_resp.chat_control_token

let test_keeper_memory_facts_activity_and_health_decoders () =
  (* 1. Endpoint builders *)
  Alcotest.(check string) "memory-facts path"
    "/api/v1/keepers/e-masc-leader/memory-facts"
    (Wire_knowledge.keeper_memory_facts_path ~keeper:"e-masc-leader");
  Alcotest.(check string) "memory-activity path"
    "/api/v1/keepers/e-masc-leader/memory-journal?activity=1&limit=50"
    (Wire_knowledge.keeper_memory_activity_path ~keeper:"e-masc-leader" ());
  Alcotest.(check string) "memory-health fleet path"
    "/api/v1/dashboard/keeper-memory-health"
    (Wire_knowledge.keeper_memory_health_path ());
  Alcotest.(check string) "memory-health scoped path"
    "/api/v1/dashboard/keeper-memory-health?keeper=alpha%201"
    (Wire_knowledge.keeper_memory_health_path ~keeper:"alpha 1" ());

  (* 2. decode_keeper_memory_facts: present + observed/board/derived + retrieval + source_bound *)
  let facts_json =
    parse_json
      {|{
        "keeper": "alpha",
        "dashboard_surface": "keeper_memory_facts",
        "ordinary": {
          "present": true,
          "revision": 12,
          "snapshot_sha256": "abc123def456",
          "updated_at": 1795252000.0,
          "facts": [
            {
              "memory_id": "m-1",
              "claim": "Always run dune build @check",
              "category": "lesson",
              "origin": "authored",
              "first_seen": 1795200000.0,
              "last_seen": 1795251000.0,
              "basis": { "kind": "observed", "board": { "post_id": "p-42", "comment_id": "c-7" } },
              "events": {
                "retrieved_count": 5,
                "retrieved_distinct_days": 2,
                "last_retrieved_at": 1795251500.0,
                "retracted_count": 0,
                "revised_from": ["m-0"]
              }
            },
            {
              "memory_id": "m-2",
              "claim": "Derived synthesis rule",
              "category": "custom_topic",
              "origin": "injected",
              "first_seen": 1795200100.0,
              "last_seen": 1795251100.0,
              "basis": { "kind": "derived", "derivations": [{ "rule_id": "r-synth", "premise_ids": ["m-1"] }] },
              "events": {
                "retrieved_count": 0,
                "retrieved_distinct_days": 0,
                "last_retrieved_at": null,
                "retracted_count": 1,
                "revised_from": []
              }
            }
          ],
          "support_invalidations": [
            {
              "memory_id": "m-inv",
              "claim": "Stale derived claim",
              "basis": { "kind": "observed" },
              "missing_premise_ids": ["m-gone"]
            }
          ]
        },
        "source_bound": {
          "present": true,
          "revision": 3,
          "updated_at": 1795252000.0,
          "facts": [
            { "claim": "Config lives in runtime.toml", "first_seen": 1795210000.0, "path": "docs/README.md", "sha256": "deadbeef" }
          ],
          "invalidations": [
            { "source_path": "docs/OLD.md", "invalidated_at": 1795250000.0, "reason": "source_changed" }
          ]
        },
        "events_unreadable_lines": 0,
        "events_read_error": null
      }|}
  in
  let mf = expect_ok "memory facts present" (Wire_knowledge.decode_keeper_memory_facts facts_json) in
  Alcotest.(check string) "facts keeper" "alpha" mf.keeper;
  (match mf.ordinary with
  | Wire_knowledge.Memory_store_present ord ->
      Alcotest.(check int) "ordinary rev" 12 ord.revision;
      Alcotest.(check int) "2 ordinary facts" 2 (List.length ord.facts);
      Alcotest.(check int) "1 support invalidation" 1 (List.length ord.support_invalidations);
      let f0 = List.nth ord.facts 0 in
      let f1 = List.nth ord.facts 1 in
      Alcotest.(check string) "cat0" "lesson"
        (Wire_knowledge.memory_fact_category_to_string f0.category);
      Alcotest.(check string) "cat1 custom" "custom_topic"
        (Wire_knowledge.memory_fact_category_to_string f1.category);
      (match f0.events.retrieval with
      | Wire_knowledge.Retrieved { count = 5; distinct_days = 2; _ } -> ()
      | Wire_knowledge.Retrieved _ | Wire_knowledge.Never_retrieved ->
          Alcotest.fail "expected Retrieved 5/2");
      (match f1.events.retrieval with
      | Wire_knowledge.Never_retrieved -> ()
      | Wire_knowledge.Retrieved _ -> Alcotest.fail "expected Never_retrieved")
  | Wire_knowledge.Memory_store_absent | Wire_knowledge.Memory_store_read_error _ ->
      Alcotest.fail "expected present ordinary memory");
  (match mf.source_bound with
  | Wire_knowledge.Memory_store_present sb ->
      Alcotest.(check int) "1 source fact" 1 (List.length sb.facts);
      Alcotest.(check int) "1 source invalidation" 1 (List.length sb.invalidations)
  | Wire_knowledge.Memory_store_absent | Wire_knowledge.Memory_store_read_error _ ->
      Alcotest.fail "expected present source_bound memory");
  (* Absent & read_error states *)
  let mf_states =
    expect_ok "absent + read_error"
      (Wire_knowledge.decode_keeper_memory_facts
         (parse_json
            {|{
              "keeper": "beta",
              "ordinary": { "present": false },
              "source_bound": { "read_error": "disk corrupt" },
              "events_unreadable_lines": 2,
              "events_read_error": "tail truncated"
            }|}))
  in
  (match mf_states.ordinary, mf_states.source_bound with
  | Wire_knowledge.Memory_store_absent, Wire_knowledge.Memory_store_read_error "disk corrupt" -> ()
  | _ -> Alcotest.fail "expected absent ordinary + read_error source_bound");
  (* Strict rejections on memory-facts *)
  ignore
    (expect_err "reject forbidden category 'all'"
       (Wire_knowledge.decode_keeper_memory_facts
          (parse_json
             {|{
               "keeper": "alpha",
               "ordinary": {
                 "present": true, "revision": 1, "snapshot_sha256": "aa", "updated_at": 1.0,
                 "facts": [{
                   "memory_id": "m1", "claim": "x", "category": "all", "origin": "authored",
                   "first_seen": 1.0, "last_seen": 2.0, "basis": {"kind": "observed"},
                   "events": {"retrieved_count": 0, "retrieved_distinct_days": 0, "last_retrieved_at": null, "retracted_count": 0, "revised_from": []}
                 }],
                 "support_invalidations": []
               },
               "source_bound": { "present": false },
               "events_unreadable_lines": 0,
               "events_read_error": null
             }|}))
      : string);
  ignore
    (expect_err "reject inconsistent retrieval count=0 with timestamp"
       (Wire_knowledge.decode_keeper_memory_facts
          (parse_json
             {|{
               "keeper": "alpha",
               "ordinary": {
                 "present": true, "revision": 1, "snapshot_sha256": "aa", "updated_at": 1.0,
                 "facts": [{
                   "memory_id": "m1", "claim": "x", "category": "fact", "origin": "authored",
                   "first_seen": 1.0, "last_seen": 2.0, "basis": {"kind": "observed"},
                   "events": {"retrieved_count": 0, "retrieved_distinct_days": 0, "last_retrieved_at": 5.0, "retracted_count": 0, "revised_from": []}
                 }],
                 "support_invalidations": []
               },
               "source_bound": { "present": false },
               "events_unreadable_lines": 0,
               "events_read_error": null
             }|}))
      : string);

  (* 3. decode_keeper_memory_activity: all 8 closed kinds + shape rejections *)
  let act_json =
    parse_json
      {|{
        "keeper": "alpha",
        "returned": 8,
        "undecodable_lines": 1,
        "entries": [],
        "activity": {
          "limit": 50,
          "journal_lines": 8,
          "notes": ["oldest lines truncated"],
          "events": [
            {"identity":"e1","recorded_at":1795252001.0,"revision":1,"kind":"created","before":[],"after":[{"memory_id":"f1","claim":"c1"}],"reason":null},
            {"identity":"e2","recorded_at":1795252002.0,"revision":2,"kind":"reobserved","before":[{"memory_id":"f1","claim":"c1"}],"after":[{"memory_id":"f1","claim":"c1"}],"reason":null},
            {"identity":"e3","recorded_at":1795252003.0,"revision":3,"kind":"revised","before":[{"memory_id":"f1","claim":"c1"}],"after":[{"memory_id":"f2","claim":"c2"}],"reason":"refined"},
            {"identity":"e4","recorded_at":1795252004.0,"revision":4,"kind":"absorbed","before":[{"memory_id":"f2","claim":"c2"}],"after":[{"memory_id":"f3","claim":"c3"}],"reason":"merged"},
            {"identity":"e5","recorded_at":1795252005.0,"revision":5,"kind":"retracted","before":[{"memory_id":"f3","claim":"c3"}],"after":[],"reason":"superseded"},
            {"identity":"e6","recorded_at":1795252006.0,"revision":6,"kind":"removed","before":[{"memory_id":"f4","claim":"c4"}],"after":[],"reason":null},
            {"identity":"e7","recorded_at":1795252007.0,"revision":7,"kind":"invalidated","before":[{"memory_id":"f5","claim":"c5"}],"after":[],"reason":"missing premise"},
            {"identity":"e8","recorded_at":1795252008.0,"revision":8,"kind":"relation_unavailable","before":[{"memory_id":"f6","claim":"c6"}],"after":[],"reason":"legacy log missing link"}
          ]
        }
      }|}
  in
  let act = expect_ok "memory activity 8 kinds" (Wire_knowledge.decode_keeper_memory_activity act_json) in
  Alcotest.(check int) "8 events decoded" 8 (List.length act.events);
  Alcotest.(check int) "undecodable_lines" 1 act.undecodable_lines;
  Alcotest.(check bool) "kind 0 created" true
    (Wire_knowledge.equal_memory_activity_kind (List.nth act.events 0).kind
       Wire_knowledge.Activity_created);
  Alcotest.(check bool) "kind 7 relation_unavailable" true
    (Wire_knowledge.equal_memory_activity_kind (List.nth act.events 7).kind
       Wire_knowledge.Activity_relation_unavailable);
  ignore
    (expect_err "reject unknown activity kind"
       (Wire_knowledge.decode_keeper_memory_activity
          (parse_json
             {|{"keeper":"alpha","undecodable_lines":0,"activity":{"limit":10,"journal_lines":1,"notes":[],"events":[{"identity":"x","recorded_at":1.0,"revision":1,"kind":"teleported","before":[],"after":[{"memory_id":"f1","claim":"c1"}],"reason":null}]}}|}))
      : string);
  ignore
    (expect_err "reject created with non-empty before"
       (Wire_knowledge.decode_keeper_memory_activity
          (parse_json
             {|{"keeper":"alpha","undecodable_lines":0,"activity":{"limit":10,"journal_lines":1,"notes":[],"events":[{"identity":"x","recorded_at":1.0,"revision":1,"kind":"created","before":[{"memory_id":"f0","claim":"old"}],"after":[{"memory_id":"f1","claim":"c1"}],"reason":null}]}}|}))
      : string);
  ignore
    (expect_err "reject removed with null claim"
       (Wire_knowledge.decode_keeper_memory_activity
          (parse_json
             {|{"keeper":"alpha","undecodable_lines":0,"activity":{"limit":10,"journal_lines":1,"notes":[],"events":[{"identity":"x","recorded_at":1.0,"revision":1,"kind":"removed","before":[{"memory_id":"f0","claim":null}],"after":[],"reason":null}]}}|}))
      : string);
  ignore
    (expect_err "reject relation_unavailable with empty before"
       (Wire_knowledge.decode_keeper_memory_activity
          (parse_json
             {|{"keeper":"alpha","undecodable_lines":0,"activity":{"limit":10,"journal_lines":1,"notes":[],"events":[{"identity":"x","recorded_at":1.0,"revision":1,"kind":"relation_unavailable","before":[],"after":[{"memory_id":"f1","claim":"c1"}],"reason":"missing link"}]}}|}))
      : string);
  ignore
    (expect_err "reject activity event missing reason field"
       (Wire_knowledge.decode_keeper_memory_activity
          (parse_json
             {|{"keeper":"alpha","undecodable_lines":0,"activity":{"limit":10,"journal_lines":1,"notes":[],"events":[{"identity":"x","recorded_at":1.0,"revision":1,"kind":"created","before":[],"after":[{"memory_id":"f1","claim":"c1"}]}]}}|}))
      : string);
  ignore
    (expect_err "reject activity event with negative recorded_at"
       (Wire_knowledge.decode_keeper_memory_activity
          (parse_json
             {|{"keeper":"alpha","undecodable_lines":0,"activity":{"limit":10,"journal_lines":1,"notes":[],"events":[{"identity":"x","recorded_at":-5.0,"revision":1,"kind":"created","before":[],"after":[{"memory_id":"f1","claim":"c1"}],"reason":null}]}}|}))
      : string);
  ignore
    (expect_err "reject duplicate activity identities"
       (Wire_knowledge.decode_keeper_memory_activity
          (parse_json
             {|{"keeper":"alpha","undecodable_lines":0,"activity":{"limit":10,"journal_lines":2,"notes":[],"events":[{"identity":"dup","recorded_at":1.0,"revision":1,"kind":"created","before":[],"after":[{"memory_id":"f1","claim":"c1"}],"reason":null},{"identity":"dup","recorded_at":2.0,"revision":2,"kind":"created","before":[],"after":[{"memory_id":"f2","claim":"c2"}],"reason":null}]}}|}))
      : string);
  (* Additional strict memory-facts rejections: bad custom category, empty premise_ids, missing support_invalidations *)
  ignore
    (expect_err "reject consecutive underscore category a__b"
       (Wire_knowledge.decode_keeper_memory_facts
          (parse_json
             {|{"keeper":"alpha","ordinary":{"present":true,"revision":1,"snapshot_sha256":"aa","updated_at":1.0,"facts":[{"memory_id":"m1","claim":"x","category":"a__b","origin":"authored","first_seen":1.0,"last_seen":2.0,"basis":{"kind":"observed"},"events":{"retrieved_count":0,"retrieved_distinct_days":0,"last_retrieved_at":null,"retracted_count":0,"revised_from":[]}}],"support_invalidations":[]},"source_bound":{"present":false},"events_unreadable_lines":0,"events_read_error":null}|}))
      : string);
  ignore
    (expect_err "reject trailing underscore category a_"
       (Wire_knowledge.decode_keeper_memory_facts
          (parse_json
             {|{"keeper":"alpha","ordinary":{"present":true,"revision":1,"snapshot_sha256":"aa","updated_at":1.0,"facts":[{"memory_id":"m1","claim":"x","category":"a_","origin":"authored","first_seen":1.0,"last_seen":2.0,"basis":{"kind":"observed"},"events":{"retrieved_count":0,"retrieved_distinct_days":0,"last_retrieved_at":null,"retracted_count":0,"revised_from":[]}}],"support_invalidations":[]},"source_bound":{"present":false},"events_unreadable_lines":0,"events_read_error":null}|}))
      : string);
  ignore
    (expect_err "reject derived fact with empty premise_ids"
       (Wire_knowledge.decode_keeper_memory_facts
          (parse_json
             {|{"keeper":"alpha","ordinary":{"present":true,"revision":1,"snapshot_sha256":"aa","updated_at":1.0,"facts":[{"memory_id":"m1","claim":"x","category":"fact","origin":"authored","first_seen":1.0,"last_seen":2.0,"basis":{"kind":"derived","derivations":[{"rule_id":"r1","premise_ids":[]}]},"events":{"retrieved_count":0,"retrieved_distinct_days":0,"last_retrieved_at":null,"retracted_count":0,"revised_from":[]}}],"support_invalidations":[]},"source_bound":{"present":false},"events_unreadable_lines":0,"events_read_error":null}|}))
      : string);
  ignore
    (expect_err "reject ordinary present missing support_invalidations"
       (Wire_knowledge.decode_keeper_memory_facts
          (parse_json
             {|{"keeper":"alpha","ordinary":{"present":true,"revision":1,"snapshot_sha256":"aa","updated_at":1.0,"facts":[]},"source_bound":{"present":false},"events_unreadable_lines":0,"events_read_error":null}|}))
      : string);

  (* 4. decode_keeper_memory_health_fleet (v19): 24-bin age_bins + facts_by_hour + strict rejections *)
  let bins_24_str =
    "[" ^ String.concat "," (List.init 24 (fun i -> string_of_int i)) ^ "]"
  in
  let health_json =
    parse_json
      (Printf.sprintf
         {|{
           "schema": "keeper.memory_os.current_health.v19",
           "generated_at": 1795252099.0,
           "keepers": [
             {
               "keeper_id": "alpha",
               "revision": 12,
               "updated_at": 1795252000.0,
               "facts": 276,
               "observed_facts": 200,
               "derived_facts": 76,
               "support_invalidations": 1,
               "snapshot_bytes": 40960,
               "added": 14,
               "removed": 3,
               "snapshot_present": true,
               "age_bins": %s,
               "facts_by_hour": [
                 {"recorded_at": 1795240000.0, "facts": 265},
                 {"recorded_at": 1795252000.0, "facts": 276}
               ],
               "librarian_failures": 0,
               "vision_ingest_errors": 0,
               "read_error": null,
               "source_revision": 3,
               "source_facts": 5,
               "source_invalidations": 0,
               "source_snapshot_bytes": 1024,
               "source_snapshot_present": true,
               "source_read_error": null,
               "alerts": [
                 {"code": "stale_derivation", "severity": "warn", "target": "alpha", "label": "Stale", "message": "1 invalidated"}
               ]
             },
             {
               "keeper_id": "beta",
               "revision": 0,
               "updated_at": null,
               "facts": 0,
               "observed_facts": 0,
               "derived_facts": 0,
               "support_invalidations": 0,
               "snapshot_bytes": 0,
               "added": 0,
               "removed": 0,
               "snapshot_present": false,
               "age_bins": null,
               "facts_by_hour": [],
               "librarian_failures": 0,
               "vision_ingest_errors": 0,
               "read_error": null,
               "source_revision": 0,
               "source_facts": 0,
               "source_invalidations": 0,
               "source_snapshot_bytes": 0,
               "source_snapshot_present": false,
               "source_read_error": null,
               "alerts": []
             }
           ]
         }|}
         bins_24_str)
  in
  let fleet = expect_ok "memory health v19" (Wire_knowledge.decode_keeper_memory_health_fleet health_json) in
  Alcotest.(check int) "2 health rows" 2 (List.length fleet.keepers);
  let h0 = List.nth fleet.keepers 0 in
  let h1 = List.nth fleet.keepers 1 in
  Alcotest.(check int) "alpha facts" 276 h0.facts;
  Alcotest.(check int) "alpha source_facts" 5 h0.source_facts;
  Alcotest.(check int) "alpha facts_by_hour len" 2 (List.length h0.facts_by_hour);
  (match h0.age_bins with
  | Some arr ->
      Alcotest.(check int) "24 age bins" 24 (Array.length arr);
      Alcotest.(check int) "bin 23 value" 23 arr.(23)
  | None -> Alcotest.fail "expected Some age_bins");
  Alcotest.(check bool) "beta absent age_bins is None" true (Option.is_none h1.age_bins);
  ignore
    (expect_err "reject wrong health schema"
       (Wire_knowledge.decode_keeper_memory_health_fleet
          (parse_json {|{"schema":"keeper.memory_os.current_health.v18","generated_at":1.0,"keepers":[]}|}))
      : string);
  ignore
    (expect_err "reject missing v19 source_* fields on health row"
       (Wire_knowledge.decode_keeper_memory_health_fleet
          (parse_json
             (Printf.sprintf
                {|{"schema":"keeper.memory_os.current_health.v19","generated_at":1.0,"keepers":[{"keeper_id":"a","revision":1,"updated_at":1.0,"facts":1,"observed_facts":1,"derived_facts":0,"support_invalidations":0,"snapshot_bytes":10,"added":0,"removed":0,"snapshot_present":true,"age_bins":%s,"facts_by_hour":[],"librarian_failures":0,"vision_ingest_errors":0,"read_error":null,"alerts":[]}]}|}
                bins_24_str)))
      : string);
  ignore
    (expect_err "reject blank source_read_error on health row"
       (Wire_knowledge.decode_keeper_memory_health_fleet
          (parse_json
             (Printf.sprintf
                {|{"schema":"keeper.memory_os.current_health.v19","generated_at":1.0,"keepers":[{"keeper_id":"a","revision":1,"updated_at":1.0,"facts":1,"observed_facts":1,"derived_facts":0,"support_invalidations":0,"snapshot_bytes":10,"added":0,"removed":0,"snapshot_present":true,"age_bins":%s,"facts_by_hour":[],"librarian_failures":0,"vision_ingest_errors":0,"read_error":null,"source_revision":0,"source_facts":0,"source_invalidations":0,"source_snapshot_bytes":0,"source_snapshot_present":false,"source_read_error":"   ","alerts":[]}]}|}
                bins_24_str)))
      : string);
  ignore
    (expect_err "reject 23-element age_bins"
       (Wire_knowledge.decode_keeper_memory_health_fleet
          (parse_json
             {|{"schema":"keeper.memory_os.current_health.v19","generated_at":1.0,"keepers":[{"keeper_id":"a","revision":1,"updated_at":1.0,"facts":1,"observed_facts":1,"derived_facts":0,"support_invalidations":0,"snapshot_bytes":10,"added":0,"removed":0,"snapshot_present":true,"age_bins":[0,0,0],"facts_by_hour":[],"librarian_failures":0,"vision_ingest_errors":0,"read_error":null,"source_revision":0,"source_facts":0,"source_invalidations":0,"source_snapshot_bytes":0,"source_snapshot_present":false,"source_read_error":null,"alerts":[]}]}|}))
      : string)

(* Every Keeper input is a [user] row; only [speaker_authority] says whether
   the operator wrote it. *)
let test_chat_history_speaker () =
  let rows =
    expect_ok "user rows by speaker"
      (Wire_fleet.decode_chat_history
         (parse_json
            {|[
              {"id":"u-1","role":"user","content":"a","ts":1.0,
               "speaker_authority":"owner","surface":{"kind":"dashboard"}},
              {"id":"u-2","role":"user","content":"b","ts":2.0,
               "speaker_id":"leader-1","speaker_name":"leader-1",
               "speaker_authority":"keeper","surface":{"kind":"broadcast"}},
              {"id":"u-3","role":"user","content":"c","ts":3.0,
               "speaker_id":"reviewer-2","speaker_authority":"keeper",
               "surface":{"kind":"agent"}},
              {"id":"u-4","role":"user","content":"d","ts":4.0,
               "speaker_id":"U1","speaker_name":"slack-author",
               "speaker_authority":"external",
               "surface":{"kind":"slack","channel_id":"C1"}},
              {"id":"u-5","role":"user","content":"e","ts":5.0,
               "speaker_id":"someone"},
              {"id":"u-6","role":"operator","content":"f","ts":6.0}
            ]|}))
  in
  let role_of id =
    (List.find (fun (m : Wire_fleet.chat_message) -> String.equal m.id id) rows)
      .role
  in
  Alcotest.(check bool) "owner row is the operator's" true
    (role_of "u-1" = Wire_fleet.Role_user);
  Alcotest.(check bool) "keeper broadcast names the keeper and the route" true
    (role_of "u-2"
    = Wire_fleet.Role_peer
        {
          peer = Wire_fleet.Peer_keeper "leader-1";
          surface = Some Wire_fleet.Surface_broadcast;
        });
  Alcotest.(check bool) "keeper without a name is named by its id" true
    (role_of "u-3"
    = Wire_fleet.Role_peer
        {
          peer = Wire_fleet.Peer_keeper "reviewer-2";
          surface = Some Wire_fleet.Surface_agent;
        });
  Alcotest.(check bool) "connector author keeps its name and route" true
    (role_of "u-4"
    = Wire_fleet.Role_peer
        {
          peer = Wire_fleet.Peer_external "slack-author";
          surface = Some Wire_fleet.Surface_slack;
        });
  Alcotest.(check bool) "row without an authority is unresolved, not the operator's"
    true
    (role_of "u-5"
    = Wire_fleet.Role_peer
        { peer = Wire_fleet.Peer_unresolved (Some "someone"); surface = None });
  Alcotest.(check bool) "operator role is the operator's" true
    (role_of "u-6" = Wire_fleet.Role_user);
  ignore
    (expect_err "unknown speaker_authority rejected"
       (Wire_fleet.decode_chat_history
          (parse_json
             {|[{"id":"u-7","role":"user","content":"g","ts":7.0,
                 "speaker_authority":"admin"}]|}))
      : string);
  ignore
    (expect_err "unknown surface kind on a peer row rejected"
       (Wire_fleet.decode_chat_history
          (parse_json
             {|[{"id":"u-8","role":"user","content":"h","ts":8.0,
                 "speaker_id":"leader-1","speaker_authority":"keeper",
                 "surface":{"kind":"pigeon"}}]|}))
      : string)

(* A quota window that still has room plus a $0 credit window is a live
   subscription ($0 Sub). Credit alone, or a spent quota window, is exhausted. *)
let test_account_cost_state_credit_and_quota () =
  let window utilization =
    {
      Wire_runtime.limit_id = None;
      kind = Wire_runtime.Window_five_hour;
      role = Wire_runtime.Role_gates_model_calls;
      utilization;
      resets_at_unix = None;
      observed_at_unix = 0.0;
    }
  in
  let credit_zero =
    window
      (Wire_runtime.Util_credit_balance
         { currency = "USD"; total = Some 10.0; remaining = 0.0 })
  in
  let cost windows =
    Format_val.format_cost
      (Wire_runtime.classify_account_cost_state
         (Wire_runtime.Account_reported windows))
      ~lang:Say.Lang_en
  in
  Alcotest.(check string) "7 percent used quota + $0 credit" "$0 Sub"
    (cost [ window (Wire_runtime.Util_percent 7); credit_zero ]);
  Alcotest.(check string) "fraction 0.07 quota + $0 credit" "$0 Sub"
    (cost [ window (Wire_runtime.Util_fraction 0.07); credit_zero ]);
  Alcotest.(check string) "unlimited quota + $0 credit" "$0 Sub"
    (cost [ window Wire_runtime.Util_credit_unlimited; credit_zero ]);
  Alcotest.(check string) "$0 credit alone" "$0 Exhausted" (cost [ credit_zero ]);
  Alcotest.(check string) "100 percent used quota + $0 credit" "$0 Exhausted"
    (cost [ window (Wire_runtime.Util_percent 100); credit_zero ]);
  Alcotest.(check string) "fraction 1.0 quota + $0 credit" "$0 Exhausted"
    (cost [ window (Wire_runtime.Util_fraction 1.0); credit_zero ]);
  Alcotest.(check string) "NaN fraction quota + $0 credit" "$0 Exhausted"
    (cost [ window (Wire_runtime.Util_fraction Float.nan); credit_zero ])

let test_feature_wave1_wire_decoders () =
  (* 1. Live GET /api/v1/published-artifacts native body._blob + detail *)
  let live_artifacts =
    expect_ok "live published-artifacts native body._blob"
      (Wire_knowledge.decode_artifacts_list
         (parse_json
            {|{
              "artifacts": [
                {
                  "id": "artifact-0123456789abcdef0123456789abcdef",
                  "url": "/api/v1/published-artifacts/artifact-0123456789abcdef0123456789abcdef",
                  "revision": 3,
                  "title": "Weekly HTML Brief",
                  "summary": "Executive summary",
                  "format": "html",
                  "author": "alpha-leader",
                  "created_at": 1795254000.0,
                  "body": {
                    "_blob": {
                      "sha256": "abc123def456",
                      "bytes": 2048,
                      "mime": "text/html",
                      "preview": "<!doctype html><h1>Weekly</h1>"
                    }
                  }
                },
                {
                  "id": "art-direct-body",
                  "url": "/api/v1/published-artifacts/art-direct-body",
                  "revision": 1,
                  "title": "Direct Body Note",
                  "summary": "Direct summary",
                  "format": "markdown",
                  "author": "artifact-author",
                  "created_at": 1795254001.0,
                  "body": {
                    "_blob": {
                      "sha256": "direct777",
                      "bytes": 128,
                      "mime": "text/markdown"
                    }
                  }
                }
              ]
            }|}))
  in
  Alcotest.(check int) "2 artifacts decoded" 2 (List.length live_artifacts);
  let a0 = List.nth live_artifacts 0 in
  let a1 = List.nth live_artifacts 1 in
  Alcotest.(check string) "live id" "artifact-0123456789abcdef0123456789abcdef" a0.id;
  Alcotest.(check int) "live revision" 3 a0.revision;
  Alcotest.(check bool) "live format = Html" true
    (Wire_knowledge.artifact_format_of_entry a0 = `Html);
  Alcotest.(check string) "live _blob sha256" "abc123def456" a0.body.sha256;
  Alcotest.(check int) "live _blob bytes" 2048 a0.body.bytes;
  Alcotest.(check string) "live _blob mime" "text/html" a0.body.mime;
  Alcotest.(check string) "second artifact sha" "direct777" a1.body.sha256;
  Alcotest.(check bool) "second artifact format = Markdown" true
    (Wire_knowledge.artifact_format_of_entry a1 = `Markdown);
  Alcotest.(check string) "detail path with revision"
    "/api/v1/published-artifacts/art-weekly-01?revision=3"
    (Wire_knowledge.published_artifact_detail_path ~id:"art-weekly-01" ~revision:3 ());
  let detail =
    expect_ok "published artifact detail with native body._blob"
      (Wire_knowledge.decode_published_artifact_detail
         (parse_json
            {|{
              "artifact": {
                "id": "artifact-0123456789abcdef0123456789abcdef",
                "url": "/api/v1/published-artifacts/artifact-0123456789abcdef0123456789abcdef",
                "revision": 3,
                "title": "Weekly HTML Brief",
                "summary": "Executive summary",
                "format": "html",
                "author": "alpha-leader",
                "created_at": 1795254000.0,
                "body": { "_blob": { "sha256": "abc123def456", "bytes": 42, "mime": "text/html" } }
              },
              "content": "<!doctype html><h1>Weekly Full HTML</h1>",
              "revisions": [
                {
                  "revision": 2,
                  "title": "Weekly HTML Brief",
                  "summary": "Rev 2",
                  "format": "html",
                  "author": "alpha-leader",
                  "created_at_unix": 1795250000.0,
                  "body": { "_blob": { "sha256": "prevsha", "bytes": 30, "mime": "text/html" } }
                }
              ],
              "shared": true,
              "share_version": 2
            }|}))
  in
  Alcotest.(check string) "detail content"
    "<!doctype html><h1>Weekly Full HTML</h1>" detail.content;
  Alcotest.(check int) "detail revisions" 1 (List.length detail.revisions);
  Alcotest.(check string) "detail revision _blob sha" "prevsha"
    (List.hd detail.revisions).sha256;
  Alcotest.(check bool) "detail shared" true detail.shared;

  (* 2. Rich Browser Lane clients + inventoryIssues + per-tab read *)
  let bl =
    expect_ok "rich browser lane clients"
      (Wire_runtime.decode_browser_lane
         (parse_json
            {|{
              "ok": true,
              "data": {
                "clients": [
                  {
                    "clientId": "ego-space-1",
                    "browser": "Ego Browser",
                    "version": "131.0",
                    "engineVersion": "131.0.6778",
                    "transport": "ego",
                    "space": { "id": 1, "name": "research" },
                    "spaceObservation": { "ownership": "agent", "spaceId": 1, "spaceName": "research" },
                    "spacePresence": { "state": "present" },
                    "interactions": [
                      { "requestId": "req-1", "actor": "alpha", "action": "navigate", "tabId": 42, "phase": "running" }
                    ],
                    "lastActivities": []
                  }
                ],
                "inventoryIssues": [
                  { "kind": "ego_user_owned_space", "instanceId": "inst-1", "space": "personal" }
                ],
                "inventoryComplete": false,
                "automatic": { "browse": { "ok": true, "data": {} } }
              }
            }|}))
  in
  Alcotest.(check int) "1 browser client decoded" 1 (List.length bl.clients);
  let c0 = List.hd bl.clients in
  Alcotest.(check string) "client id" "ego-space-1" c0.client_id;
  Alcotest.(check (option string)) "client ownership" (Some "agent") c0.ownership;
  Alcotest.(check (option string)) "client presence" (Some "present") c0.presence_state;
  Alcotest.(check int) "1 inventory issue decoded" 1 (List.length bl.issues);
  Alcotest.(check string) "tabs request json"
    {|{"lane":"live","clientId":"ego-space-1"}|}
    (Yojson.Safe.to_string
       (Wire_runtime.encode_browser_tabs_request ~client_id:"ego-space-1"));
  let tabs_resp =
    expect_ok "browser tabs read response"
      (Wire_runtime.decode_browser_tabs_response
         (parse_json
            {|{
              "ok": true,
              "data": {
                "clientId": "ego-space-1",
                "complete": true,
                "unavailableTabs": [],
                "tabs": [
                  {
                    "id": 42,
                    "title": "MASC Repo",
                    "url": "https://github.com/jeong-sik/masc",
                    "active": true,
                    "windowId": 1,
                    "egoPage": { "openedBy": "agent", "label": "research" },
                    "dialog": { "type": "confirm" }
                  }
                ]
              }
            }|}))
  in
  Alcotest.(check int) "1 browser tab decoded" 1 (List.length tabs_resp.tabs);
  let t0_row = List.hd tabs_resp.tabs in
  Alcotest.(check bool) "tab dialog present" true t0_row.dialog_present;
  Alcotest.(check (option string)) "tab dialog kind" (Some "confirm") t0_row.dialog_kind;

  (* 3. Lane Addons decoder (live object phase:{kind,...}) + Wire_observer routing *)
  let addons =
    expect_ok "lane addons snapshot with live object phase"
      (Wire_runtime.decode_lane_addons
         (parse_json
            {|{
              "configuration": {
                "complete": true,
                "declarations": [
                  {
                    "id": "browser-ego",
                    "source_path": ".masc/config/addons/browser-ego.toml",
                    "enabled": true,
                    "source_revision": "r1",
                    "desired_revision": "r1",
                    "applied_revision": "r1",
                    "instance_id": "inst-b1",
                    "application": { "kind": "applied", "messages": [] },
                    "ui_category": "browser"
                  }
                ],
                "issues": []
              },
              "instances": [
                {
                  "runtime_presence": "live",
                  "instance_id": "inst-b1",
                  "addon_id": "browser-ego",
                  "title": "Browser Ego Addon",
                  "revision": "r1",
                  "phase": { "kind": "observing" },
                  "execution_authority": { "kind": "host_process" },
                  "observation_seq": 12,
                  "rows_count": 4,
                  "observation_pending": false,
                  "visibility": { "kind": "shared" },
                  "host_requests": { "cycles": 12, "waiting": [] },
                  "action_schema": {
                    "type": "object",
                    "properties": { "action": { "enum": ["navigate", "read_tabs"] } }
                  },
                  "configuration": { "id": "browser-ego" }
                },
                {
                  "runtime_presence": "retained",
                  "instance_id": "inst-b2",
                  "addon_id": "browser-failed",
                  "title": "Failed Addon",
                  "revision": "r1",
                  "phase": { "kind": "failed", "message": "socket closed" },
                  "execution_authority": { "kind": "container" },
                  "observation_seq": 3,
                  "rows_count": 0,
                  "observation_pending": false,
                  "visibility": { "kind": "operator" },
                  "host_requests": { "cycles": 3, "waiting": [] }
                }
              ]
            }|}))
  in
  Alcotest.(check int) "1 addon declaration" 1 (List.length addons.declarations);
  Alcotest.(check int) "2 addon instances" 2 (List.length addons.instances);
  let inst0 = List.nth addons.instances 0 in
  let inst1 = List.nth addons.instances 1 in
  Alcotest.(check bool) "inst0 phase = Addon_observing" true
    (inst0.phase = Wire_runtime.Addon_observing);
  Alcotest.(check bool) "inst1 phase = Addon_failed" true
    (inst1.phase = Wire_runtime.Addon_failed);
  Alcotest.(check int) "2 action_schema actions" 2 (List.length inst0.action_names);
  (match
     Wire_observer.event_of_json
       (parse_json {|{"type":"lane_addon_changed","addon_id":"browser-ego"}|})
   with
  | Ok (Wire_observer.Dataset_changed Wire_observer.Dataset_lane_addons) -> ()
  | _ -> Alcotest.fail "expected lane_addon_changed -> Dataset_lane_addons");
  (match
     Wire_observer.event_of_json
       (parse_json {|{"type":"masc:lane:updated"}|})
   with
  | Ok (Wire_observer.Dataset_changed Wire_observer.Dataset_lane_addons) -> ()
  | _ -> Alcotest.fail "expected masc:lane:updated -> Dataset_lane_addons");
  (match
     Wire_observer.event_of_json
       (parse_json {|{"type":"workspace_dataset_changed","dataset":"browser_observation"}|})
   with
  | Ok (Wire_observer.Dataset_changed Wire_observer.Dataset_lane_addons) -> ()
  | _ -> Alcotest.fail "expected browser_observation -> Dataset_lane_addons")

(* A page the TUI cannot read in full is refused, never read around: a new
   event type could carry text the rebuilt reply would silently miss. *)
let test_wire_chat_journal_refusals () =
  let page ?(schema = "masc.keeper_chat_events.v2") ?(operation_id = "op-1")
      ?(has_more = false) ?(next_since_seq = `Null) events =
    `Assoc
      [
        ("schema", `String schema);
        ("operation_id", `String operation_id);
        ( "events",
          `List
            (List.map
               (fun event ->
                 `Assoc
                   [
                     ("v", `Int 2); ("seq", `Int 0); ("ts", `Float 1.0);
                     ("event", event);
                   ])
               events) );
        ("has_more", `Bool has_more);
        ("next_since_seq", next_since_seq);
        ("next_since_offset", `Int 0);
      ]
  in
  let decode json = Wire_chat_journal.decode_page ~operation_id:"op-1" json in
  let text_delta fields =
    `Assoc (("type", `String "text_delta") :: ("delta", `String "x") :: fields)
  in
  let owner = `Assoc [ ("content_generation", `Int 1); ("stream_scope", `Int 0) ] in
  ignore (expect_ok "a plain page" (decode (page [ text_delta [] ])));
  ignore
    (expect_err "another schema"
       (decode (page ~schema:"masc.keeper_chat_events.v1" [])));
  ignore (expect_err "another operation" (decode (page ~operation_id:"op-2" [])));
  ignore
    (expect_err "an event type the server does not journal"
       (decode (page [ `Assoc [ ("type", `String "brand_new_event") ] ])));
  ignore
    (expect_err "an owner sent both ways"
       (decode
          (page [ text_delta [ ("response", owner); ("stream_scope", `Int 0) ] ])));
  ignore
    (expect_err "a response with a third index"
       (decode
          (page
             [
               text_delta
                 [
                   ( "response",
                     `Assoc
                       [
                         ("content_generation", `Int 1);
                         ("stream_scope", `Int 0);
                         ("index", `Int 0);
                       ] );
                 ];
             ])));
  ignore
    (expect_err "more pages without a seq" (decode (page ~has_more:true [])));
  match
    decode
      (page ~has_more:true ~next_since_seq:(`Int 4)
         [ text_delta [ ("stream_scope", `Int 3) ] ])
  with
  | Ok
      {
        events =
          [
            Wire_chat_journal.Text_delta
              { owner = Wire_chat_journal.Unobserved_scope (Some 3); _ };
          ];
        next = Some { last_seq = 4; next_offset = 0 };
      } ->
      ()
  | Ok _ -> Alcotest.fail "a bare scope and the cursor pair were misread"
  | Error detail -> Alcotest.failf "a bare scope page was refused: %s" detail

let test_wave2_live_wire_codecs () =
  (* 1. Turn records (reusing live Turn_record.of_json) *)
  let tr_json =
    parse_json
      {|{
        "keeper": "alpha",
        "count": 1,
        "skipped_rows": 0,
        "health": "healthy",
        "live_turn_in_progress": false,
        "entries": [
          {
            "diff_vs_prev": null,
            "record": {
              "execution_ids": ["exec-101"],
            "keeper": "alpha",
            "agent_name": "alpha",
            "turn_kind": "direct",
            "trace_id": "trace-abc",
            "absolute_turn": 42,
            "turn_ref": "trace-abc#42",
            "blocks": [
              { "block": "keeper_instructions", "bytes": 4200, "digest": "aabbcc11223344556677889900aabbcc11223344556677889900aabbcc112233" },
              { "block": "active_goals", "bytes": 680, "digest": "ddeeff4455667788990011223344556677889900aabbccddeeff001122334455" }
            ],
            "input_components": [
              { "component": "prompt.keeper_instructions", "bytes": 4200 },
              { "component": "tool_schemas", "bytes": 8400 },
              { "component": "message_user", "bytes": 320 }
            ],
            "request_observations": [],
            "runtime_profile": "claude-sonnet-4",
            "request_runtime_profile": "claude-sonnet-4",
            "request_body_bytes": 15200,
            "transmitted_atoms": null,
            "total_atoms": null,
            "model_input_measurement": null,
            "model_input_front": null,
            "response_observed_model_input": null,
            "refused_model_input": null,
            "raw_trace_run_ref": null,
            "selected_model": "claude-sonnet-4",
            "finish_reason": "end_turn",
            "context_window": 200000,
            "provider_context_window": 200000,
            "request_latency_ms": 1240,
            "input_tokens": 24000,
            "cache_creation_input_tokens": 1200,
            "cache_read_input_tokens": 18000,
            "output_tokens": 450,
            "usage_scope": "per_request",
            "input_provenance": "measured_request",
            "ts": 1795252000.0
            }
          }
        ]
      }|}
  in
  let tr_page =
    expect_ok "decode_turn_records"
      (Wire_keeper_context.decode_turn_records tr_json)
  in
  Alcotest.(check string) "turn_records keeper" "alpha" tr_page.keeper;
  Alcotest.(check int) "turn_records 1 entry" 1 (List.length tr_page.entries);

  (* 2. Provider input manifest (live nested wire object) + part content *)
  let pi_json =
    parse_json
      {|{
        "keeper": "alpha",
        "trace_id": "trace-abc",
        "absolute_turn": 42,
        "turn_ref": "trace-abc#42",
        "runtime_profile": "claude-sonnet-4",
        "captured_at": 1795252000.0,
        "wire": {
          "phase": "settled",
          "capture_id": "cap-42",
          "provider": "anthropic",
          "model": "claude-sonnet-4",
          "http_codec": "http1",
          "stream": true,
          "body_bytes": 15200,
          "body_sha256": "fedcba9876543210"
        },
        "parts": [
          { "index": 0, "kind": "system_prompt", "bytes": 4200, "sha256": "1111aaaa" },
          { "index": 1, "kind": "message", "role": "user", "bytes": 320, "sha256": "2222bbbb" },
          { "index": 2, "kind": "tool_schema", "name": "masc_board_post", "bytes": 8400, "sha256": "3333cccc" }
        ]
      }|}
  in
  let mf =
    expect_ok "decode_provider_input_manifest"
      (Wire_keeper_context.decode_provider_input_manifest pi_json)
  in
  Alcotest.(check int) "3 provider input parts" 3 (List.length mf.parts);
  Alcotest.(check (option int)) "live nested wire.body_bytes decoded" (Some 15200)
    mf.wire_body_bytes;
  Alcotest.(check (option string)) "live nested wire.provider decoded" (Some "anthropic")
    mf.wire_provider;
  Alcotest.(check (option string)) "live nested wire.model decoded" (Some "claude-sonnet-4")
    mf.wire_model;
  Alcotest.(check (option bool)) "live nested wire.stream decoded" (Some true)
    mf.wire_stream;
  let part_json =
    parse_json
      {|{
        "keeper": "alpha",
        "turn_ref": "trace-abc#42",
        "part": { "index": 0, "kind": "system_prompt", "bytes": 4200, "sha256": "1111aaaa" },
        "text": "You are alpha keeper."
      }|}
  in
  let part_c =
    expect_ok "decode_provider_input_part"
      (Wire_keeper_context.decode_provider_input_part part_json)
  in
  Alcotest.(check string) "provider input part text" "You are alpha keeper."
    part_c.text;

  (* 3. Cache outcome (reusing live Keeper_cache_outcome_reading.of_json) *)
  let co_json =
    parse_json
      {|{
        "schema": "masc.keeper-cache-outcome.v1",
        "keeper": "alpha",
        "turn_ref": "trace-abc#42",
        "unattributed_rows": 0,
        "outcome": {
          "kind": "first_request",
          "request": {
            "turn_ref": "trace-abc#42",
            "runtime_id": "claude-sonnet-4",
            "scope": "per_request",
            "ended_at": 1795252005.0,
            "latency_ms": 1240,
            "cache_read_tokens": 18000,
            "cache_creation_tokens": 1200,
            "cache_write_lifetime": null
          },
          "other_runtime_since": null,
          "earlier": {
            "kind": "earlier",
            "request": {
              "turn_ref": "trace-abc#41",
              "runtime_id": "claude-sonnet-4",
              "scope": "per_request",
              "ended_at": 1795251940.0,
              "latency_ms": 980,
              "cache_read_tokens": 17000,
              "cache_creation_tokens": 0,
              "cache_write_lifetime": null
            },
            "idle": {
              "kind": "idle",
              "idle_s": 63.76,
              "lifetime": { "kind": "declared", "lifetime_s": 300.0, "check": "within" }
            },
            "prefix": {
              "kind": "compared",
              "system_changed": false,
              "tools_changed": false,
              "messages": { "kind": "appended", "kept": 12, "added": 2 }
            }
          }
        }
      }|}
  in
  let co =
    expect_ok "decode_cache_outcome"
      (Wire_keeper_context.decode_cache_outcome co_json)
  in
  Alcotest.(check string) "cache_outcome keeper" "alpha" co.keeper;

  (* 4. Next request forecast + turn transcript *)
  let nr_json =
    parse_json
      {|{
        "keeper": "alpha",
        "trace_id": "trace-abc",
        "checkpoint_messages": 14,
        "wake_line_bytes": 180,
        "walk": { "lane_id": "lane-primary", "declared": ["claude-sonnet-4"] },
        "candidates": [
          {
            "runtime_id": "claude-sonnet-4",
            "lane": { "kind": "agent_core" },
            "parts": {
              "ok": true,
              "reserved_measured_on_turn": 42,
              "reserved_bytes": 12600,
              "instructions_bytes": 4200,
              "schemas_bytes": 8400,
              "pinned_measured_on_turn": 42,
              "pinned_measured_on_runtime": "claude-sonnet-4",
              "pinned_bytes": 680,
              "pinned_blocks": [{ "block": "active_goals", "bytes": 680 }]
            },
            "history_atoms": 14,
            "carried": {
              "first_atom": 0, "kept_atoms": 14, "transmitted_bytes": 9200,
              "preamble_bytes": 420, "origin": { "kind": "wire_shape" }, "counted_tokens": 22500
            },
            "assembly": [
              { "slot": "system_prompt", "bytes": 4200 },
              { "slot": "tools", "bytes": 8400 },
              { "slot": "history", "atoms": 14, "of_atoms": 14, "bytes": 9200 }
            ],
            "place": { "walks_at": 0, "declared_at": 0, "rest": { "kind": "serving" } }
          }
        ]
      }|}
  in
  let nr =
    expect_ok "decode_next_request_forecast"
      (Wire_keeper_context.decode_next_request_forecast nr_json)
  in
  Alcotest.(check int) "next_request 1 candidate" 1 (List.length nr.candidates);

  let tt_json =
    parse_json
      {|{
        "keeper": "alpha",
        "turn_ref": "trace-abc#42",
        "found": true,
        "user": [{ "role": "user", "content": "Check wave 2 status", "ts": 1795252000.0 }],
        "assistant": [{ "role": "assistant", "content": "All green.", "ts": 1795252004.0 }]
      }|}
  in
  let tt =
    expect_ok "decode_turn_transcript"
      (Wire_keeper_context.decode_turn_transcript tt_json)
  in
  Alcotest.(check bool) "turn_transcript found" true tt.found;

  (* 5. Per-keeper tool stats, tool calls, tool result + unfold_json_strings *)
  let ts_json =
    parse_json
      {|{
        "keeper": "alpha",
        "window_hours": 24,
        "total_entries": 18,
        "tools": [
          { "name": "masc_board_post", "call_count": 10, "success_count": 9, "failure_count": 1,
            "avg_duration_ms": 42, "p95_duration_ms": 110, "max_duration_ms": 200, "last_used_at": "2026-11-23T05:00:00Z" }
        ],
        "timeline": [{ "hour": "05:00", "call_count": 6, "error_count": 1 }]
      }|}
  in
  let ts =
    expect_ok "decode_keeper_tool_stats"
      (Wire_keeper_context.decode_keeper_tool_stats ts_json)
  in
  Alcotest.(check int) "keeper tool stats 18 entries" 18 ts.total_entries;

  let tc_json =
    parse_json
      {|{
        "keeper": "alpha",
        "count": 2,
        "coverage_gaps": [],
        "entries": [
          {
            "ts": 1795252001.0,
            "tool": "masc_board_post",
            "execution_id": "exec-101",
            "duration_ms": 42.0,
            "wire_outcome": "ok",
            "disposition": "completed",
            "input": { "payload": "{\"nested\":true,\"n\":3}" },
            "output": "{\"post_id\":\"p-1\"}",
            "result_bytes": 18,
            "truncated_to": null
          },
          {
            "ts": 1795252002.0,
            "tool": "masc_shell",
            "execution_id": "exec-102",
            "duration_ms": 15.0,
            "wire_outcome": "unknown",
            "disposition": "deferred",
            "input": { "cmd": "ls" },
            "output": "",
            "result_bytes": 0,
            "truncated_to": null
          }
        ]
      }|}
  in
  let tc =
    expect_ok "decode_keeper_tool_calls"
      (Wire_keeper_context.decode_keeper_tool_calls tc_json)
  in
  Alcotest.(check int) "keeper tool calls 2 entries" 2 (List.length tc.entries);
  let tc_post =
    List.find
      (fun (e : Wire_keeper_context.tool_call_entry) ->
        String.equal e.tool "masc_board_post")
      tc.entries
  in
  let tc_shell =
    List.find
      (fun (e : Wire_keeper_context.tool_call_entry) ->
        String.equal e.tool "masc_shell")
      tc.entries
  in
  Alcotest.(check (option bool)) "live wire_outcome='ok' maps to ok=Some true"
    (Some true) tc_post.ok;
  Alcotest.(check (option int)) "live result_bytes decoded" (Some 18)
    tc_post.original_bytes;
  Alcotest.(check (option bool)) "live wire_outcome='unknown' maps to ok=None"
    None tc_shell.ok;
  Alcotest.(check (option string)) "live disposition='deferred' preserved"
    (Some "deferred") tc_shell.disposition;
  Alcotest.(check string) "keeper_tool_calls_path deduplicates execution_ids"
    "/api/v1/keepers/alpha/tool-calls?execution_ids=%5B%22e1%22%2C%22e2%22%5D"
    (Wire_keeper_context.keeper_tool_calls_path
       ~execution_ids:[ "e1"; "e2"; "e1" ] ~keeper:"alpha" ());
  Alcotest.(check string) "keeper_tool_result_path passes optional source_id"
    "/api/v1/keepers/alpha/tool-result?execution_id=exec-101&offset=10&source_id=src-9"
    (Wire_keeper_context.keeper_tool_result_path ~keeper:"alpha"
       ~execution_id:"exec-101" ~offset:10 ~source_id:"src-9" ());
  let unfolded = Wire_keeper_context.unfold_json_strings tc_post.input in
  (match unfolded with
  | `Assoc [ ("payload", `Assoc fields) ] ->
      Alcotest.(check bool) "unfold_json_strings expands JSON-in-string" true
        (List.mem_assoc "nested" fields)
  | _ -> Alcotest.fail "expected unfolded nested Assoc");

  let tr_res_json =
    parse_json
      {|{
        "state": "page",
        "keeper": "alpha",
        "execution_id": "exec-101",
        "source_id": "src-1",
        "body_sha256": "deadbeef",
        "recorded_bytes": 18,
        "is_error": false,
        "page": {
          "offset": 0,
          "next_offset": 18,
          "total_bytes": 18,
          "eof": true,
          "content": "{\"post_id\":\"p-1\"}",
          "encoding": "utf-8"
        }
      }|}
  in
  (match
     expect_ok "decode_tool_result"
       (Wire_keeper_context.decode_tool_result tr_res_json)
   with
  | Wire_keeper_context.Tool_result_page { execution_id = "exec-101"; eof = true; _ } -> ()
  | _ -> Alcotest.fail "expected Tool_result_page");

  (* 6. P0 LIVE /api/v1/dashboard/tools decoder (tool_inventory x tool_usage.by_tool + effective_keeper_surface) *)
  let live_tools_json =
    parse_json
      {|{
        "tool_inventory": {
          "count": 2,
          "tools": [
            {
              "name": "masc_board_post",
              "public_names": ["board_post"],
              "description": "Publish a board post",
              "surfaces": ["keeper", "mcp"],
              "direct_call_allowed": true,
              "visibility": "public"
            },
            {
              "name": "keeper_memory_search",
              "public_names": [],
              "description": "Search keeper memory",
              "surfaces": ["keeper"],
              "direct_call_allowed": true,
              "visibility": "public"
            }
          ]
        },
        "tool_usage": {
          "registered_count": 2,
          "distinct_tools_called": 1,
          "total_calls": 42,
          "by_tool": [
            {
              "name": "masc_board_post",
              "public_names": ["board_post"],
              "call_count": 42,
              "success_count": 40,
              "failure_count": 2,
              "p95_ms": 85.5
            }
          ]
        },
        "effective_keeper_surface": {
          "status": "available",
          "keeper_name": "alpha",
          "runtime_id": "claude-sonnet-4",
          "tool_delivery": { "status": "delivered" },
          "tool_surface_bytes": 8400,
          "skill_tool_surface_bytes": 1200,
          "skill_discovery_bytes": 400,
          "skill_body_bytes": 600,
          "tools": [
            { "name": "masc_board_post", "origin": "builtin" }
          ]
        },
        "sandbox_volume_gc_report": {
          "outcome": "skipped",
          "ran_at": 1795251900.0,
          "removed_count": 0,
          "reclaimed_bytes": 0
        },
        "keeper_cleanup": {
          "swept_count": 1,
          "status": "idle"
        }
      }|}
  in
  let t0 = Clock.Mono.of_ns 10_000_000_000L in
  let dash =
    expect_ok "decode_tools_dashboard live shape"
      (Wire_runtime.decode_tools_dashboard ~observed_at:t0 live_tools_json)
  in
  Alcotest.(check int) "live tools dashboard total_calls = 42" 42 dash.total_calls;
  Alcotest.(check int) "live tools dashboard 2 joined entries" 2 (List.length dash.entries);
  let e0 = List.hd dash.entries in
  Alcotest.(check (option int)) "masc_board_post joined calls = 42" (Some 42)
    (Observed.to_option e0.calls_count);
  Alcotest.(check bool) "live effective_keeper_surface with tool_delivery object decoded" true
    (match dash.effective_keeper_surface with
    | Some
        (Wire_runtime.Keeper_surface_available
           {
             keeper_name = "alpha";
             tool_delivery = "delivered";
             tool_surface_bytes = 8400;
             _;
           }) ->
        true
    | _ -> false);
  Alcotest.(check (option string)) "live sandbox_volume_gc_report outcome decoded"
    (Some "skipped") dash.volume_gc_summary;
  Alcotest.(check (option string)) "live keeper_cleanup status decoded"
    (Some "idle") dash.keeper_cleanup_summary;

  (* Flat legacy fallback still decodes cleanly *)
  let legacy_tools_json =
    parse_json
      {|{ "tools": [{ "name": "legacy_tool", "calls_24h": 7, "failure_rate_pct": 0.0 }] }|}
  in
  let dash_legacy =
    expect_ok "decode_tools_dashboard legacy flat fallback"
      (Wire_runtime.decode_tools_dashboard ~observed_at:t0 legacy_tools_json)
  in
  Alcotest.(check int) "legacy flat fallback 1 tool" 1 (List.length dash_legacy.entries);

  (* 7. Live /api/v1/skills (nested reference.identity + profile + object rejections/shadows) *)
  let skills_json =
    parse_json
      {|{
        "state": "ready",
        "snapshot": {
          "snapshot_revision": "rev-7",
          "shadows": [
            { "name": "dup-skill", "winner": { "source_id": "ws" }, "shadowed": { "source_id": "builtin" } }
          ],
          "rejections": [
            { "path": "/skills/bad", "reason": "missing_name", "detail": "SKILL.md has no name" }
          ]
        },
        "surfaces": [
          {
            "reference": {
              "identity": { "source_id": "ws", "package_id": "core", "name": "ocaml-coding" },
              "content_revision": "sha1"
            },
            "profile": {
              "execution": "instruction",
              "activation_tool": null,
              "context": { "body_bytes": 1820, "discovery_bytes": 120 }
            }
          },
          {
            "reference": {
              "identity": { "source_id": "ws", "package_id": "ops", "name": "release-flow" },
              "content_revision": "sha2"
            },
            "profile": {
              "execution": "composition",
              "activation_tool": "masc_release_run",
              "context": { "body_bytes": 940, "discovery_bytes": 80 }
            }
          }
        ]
      }|}
  in
  let sk =
    expect_ok "decode_skills_snapshot live nested shape"
      (Wire_runtime.decode_skills_snapshot skills_json)
  in
  Alcotest.(check string) "live skills state ready" "ready" sk.state;
  Alcotest.(check int) "2 skill surfaces" 2 (List.length sk.surfaces);
  Alcotest.(check string) "live skill ref formatted cleanly" "ocaml-coding (core)"
    (List.hd sk.surfaces).reference;
  Alcotest.(check string) "live skill kind instruction" "instruction"
    (List.hd sk.surfaces).kind;
  Alcotest.(check string) "live skill 2 kind composition" "composition"
    (List.nth sk.surfaces 1).kind;
  Alcotest.(check int) "1 rejected skill formatted without raw JSON" 1
    (List.length sk.rejections);
  Alcotest.(check bool) "rejection does not start with {" false
    (String.starts_with ~prefix:"{" (List.hd sk.rejections));
  Alcotest.(check int) "1 shadowed skill formatted without raw JSON" 1
    (List.length sk.shadows);
  Alcotest.(check bool) "shadow does not start with {" false
    (String.starts_with ~prefix:"{" (List.hd sk.shadows));

  (* Live /api/v1/gate/connectors configured_bindings decode *)
  let conns_json =
    parse_json
      {|{
        "connectors": [
          {
            "connector_id": "slack",
            "display_name": "Slack",
            "status": "connected",
            "available": true,
            "connected": true,
            "channel": "slack",
            "configured_bindings": [
              { "channel_id": "C01ALPHA", "keeper_name": "alpha" }
            ]
          }
        ]
      }|}
  in
  let conns =
    expect_ok "decode_connectors live configured_bindings"
      (Wire_runtime.decode_connectors conns_json)
  in
  Alcotest.(check int) "1 configured binding decoded" 1
    (List.length (List.hd conns).configured_bindings);
  Alcotest.(check string) "configured binding channel_id" "C01ALPHA"
    (List.hd (List.hd conns).configured_bindings).channel_id;

  (* Live board_comment votes_up/votes_down fallback when score absent *)
  let post_detail_json =
    parse_json
      {|{
        "post": {
          "id": "p-1", "author": "alpha", "title": "T", "body": "B",
          "post_kind": "direct", "visibility": "internal", "created_at": 1795252000.0,
          "votes_up": 5, "votes_down": 1, "comment_count": 1
        },
        "comments": [
          {
            "id": "c-1", "post_id": "p-1", "parent_id": null, "author": "beta",
            "body": "Hi", "created_at": 1795252005.0, "votes_up": 7, "votes_down": 2
          }
        ]
      }|}
  in
  let _post, comments =
    expect_ok "decode_board_thread live votes_up/votes_down"
      (Wire_knowledge.decode_board_thread ~observed_at:t0 post_detail_json)
  in
  Alcotest.(check int) "comment score computed from votes_up - votes_down" 5
    (List.hd comments).score;

  (* Live HTTP 409 Conflict body on POST /api/v1/published-artifact-shares *)
  let share_conflict_json =
    parse_json
      {|{
        "id": "artifact-00112233445566778899aabbccddeeff",
        "current": { "shared": true, "version": 4 },
        "receipt": { "outcome": "conflict" }
      }|}
  in
  let sh_resp =
    expect_ok "decode_artifact_share_response 409 conflict"
      (Wire_knowledge.decode_artifact_share_response share_conflict_json)
  in
  Alcotest.(check bool) "409 conflict decoded as `Conflict" true
    (sh_resp.outcome = `Conflict && sh_resp.version = 4 && sh_resp.shared);

  let hearths_json =
    parse_json {|{ "hearths": [{ "name": "ops", "count": 12 }, { "name": "goals", "count": 4 }] }|}
  in
  let hearths =
    expect_ok "decode_board_hearths"
      (Wire_knowledge.decode_board_hearths hearths_json)
  in
  Alcotest.(check int) "2 board hearths" 2 (List.length hearths);

  let checks_json =
    parse_json
      {|{ "checks": [{ "id": "art-1", "revision": 2, "body_sha256": "abc123", "checked": true, "change_id": "chg-9", "changed_by": "operator", "changed_at": "2026-11-23T05:00:00Z" }] }|}
  in
  let checks =
    expect_ok "decode_artifact_checks"
      (Wire_knowledge.decode_artifact_checks checks_json)
  in
  Alcotest.(check int) "1 artifact check" 1 (List.length checks);
  Alcotest.(check bool) "artifact check checked=true" true (List.hd checks).checked;

  (* Verify connector bind/unbind path builders match live server route query params *)
  Alcotest.(check string) "connector bind path uses ?name=<connector>"
    "/api/v1/gate/connector/bind?name=slack"
    (Wire_runtime.connector_bind_path ~connector:"slack");
  Alcotest.(check string) "connector unbind path uses ?name=<connector>"
    "/api/v1/gate/connector/unbind?name=slack"
    (Wire_runtime.connector_unbind_path ~connector:"slack")

let test_wave3_live_wire_codecs () =
  (* Surface 1: Fusion runs snapshot, run detail, config presets, board evidence *)
  let fusion_runs_json =
    parse_json
      {|{
        "generated_at": "2026-11-23T08:00:00Z",
        "replay": { "status": "complete", "lines_read": 12, "malformed_lines": 1, "dropped_running": 0 },
        "historical_evidence": [
          { "run_id": "run-hist-1", "post_id": "p-hist-1", "title": "Historical Fusion", "created_at": 1795253000.0 }
        ],
        "runs": [
          {
            "run_id": "run-w3-1",
            "keeper": "alpha-leader",
            "preset": "consensus-3",
            "topology": "judge_of_judges",
            "started_at": 1795253800.0,
            "finished_at": 1795253845.0,
            "status": "completed",
            "stage": "done",
            "decision": "adopt",
            "summary": "All panelists converged on option B"
          }
        ]
      }|}
  in
  let fsnap =
    expect_ok "decode_fusion_runs_snapshot"
      (Wire_runtime.decode_fusion_runs_snapshot fusion_runs_json)
  in
  Alcotest.(check int) "1 fusion run" 1 (List.length fsnap.runs);
  Alcotest.(check int) "1 historical evidence" 1
    (List.length fsnap.historical_evidence);
  Alcotest.(check bool) "replay complete with 1 malformed" true
    (match fsnap.replay with
    | Some (Wire_runtime.Replay_complete { malformed_lines = 1; lines_read = 12; _ }) -> true
    | _ -> false);
  let fusion_detail_json =
    parse_json
      {|{
        "run": {
          "run_id": "run-w3-1",
          "keeper": "alpha-leader",
          "preset": "consensus-3",
          "topology": "judge_of_judges",
          "started_at": 1795253800.0,
          "finished_at": 1795253845.0,
          "status": "completed",
          "stage": "done",
          "decision": "adopt",
          "summary": "Converged"
        },
        "evidence": {
          "status": "recorded",
          "post": {
            "id": "p-fusion-1",
            "title": "Fusion Result: run-w3-1",
            "author": "alpha-leader",
            "body": "Full evidence body",
            "meta": {
              "question": "Which architecture scales best?",
              "panel": [
                { "model": "claude-sonnet-4", "status": "answered", "answer": "Option B", "input_tokens": 1200, "output_tokens": 300 },
                { "model": "gpt-5", "status": "failed", "reason_code": "timeout", "reason_detail": "30s exceeded" }
              ],
              "judge": { "status": "completed", "decision": "adopt", "synthesis": "Option B wins cleanly" },
              "judges": [
                { "role": "final", "identity": "opus-judge", "status": "completed", "decision": "adopt", "input_tokens": 2000, "output_tokens": 500 }
              ],
              "seat_routes": [
                {
                  "phase": "panel",
                  "seat": "seat-1",
                  "route": "lane-primary",
                  "answered_by": "claude-sonnet-4",
                  "failed_attempts": [
                    { "runtime": "backup-1", "code": "rate_limit", "detail": "429" }
                  ]
                }
              ],
              "tool_trace": {
                "status": "partial",
                "observed_actors": [
                  { "phase": "panel", "actor": "alpha-leader" },
                  { "phase": "judge", "actor": "opus-judge", "judge_role": "final" }
                ],
                "dropped_events": 0,
                "gaps": [
                  { "phase": "panel", "actor": "backup-1", "reason": "official_client_uninstrumented" }
                ],
                "events": [
                  {
                    "phase": "panel",
                    "actor": "alpha-leader",
                    "event": "completed",
                    "agent_name": "alpha-leader",
                    "tool_use_id": "tu-1",
                    "turn": 1,
                    "planned_index": 0,
                    "tool_name": "masc_board_post",
                    "status": "succeeded",
                    "output": { "text": "ok", "bytes": 2, "truncated": false }
                  }
                ]
              }
            }
          }
        }
      }|}
  in
  let fdet =
    expect_ok "decode_fusion_run_detail"
      (Wire_runtime.decode_fusion_run_detail fusion_detail_json)
  in
  (match fdet.evidence with
  | Wire_runtime.Evidence_recorded post ->
      Alcotest.(check int) "2 panel rows" 2 (List.length post.panel);
      Alcotest.(check int) "1 seat route" 1 (List.length post.seat_routes);
      Alcotest.(check int) "1 failed seat attempt" 1
        (List.length (List.hd post.seat_routes).failed_attempts);
      (match post.tool_trace with
      | None -> Alcotest.fail "expected tool_trace"
      | Some tt ->
          Alcotest.(check int) "2 live object observed_actors" 2
            (List.length tt.observed_actors);
          Alcotest.(check int) "1 live object gap" 1 (List.length tt.gaps);
          Alcotest.(check bool) "live succeeded event tagged [ok]" true
            (List.exists
               (fun s ->
                 let n = String.length "[ok]" and h = String.length s in
                 let rec f i =
                   if i + n > h then false
                   else if String.sub s i n = "[ok]" then true
                   else f (i + 1)
                 in
                 f 0)
               tt.events_preview))
  | Wire_runtime.Evidence_pending | Wire_runtime.Evidence_absent ->
      Alcotest.fail "expected Evidence_recorded");
  let fcfg =
    expect_ok "decode_fusion_config_options"
      (Wire_runtime.decode_fusion_config_options
         (parse_json
            {|{
              "config": {
                "enabled": true,
                "default_preset": "consensus-3",
                "staged_judge_group_size": 3,
                "presets": [
                  {
                    "name": "consensus-3",
                    "panels": [
                      { "models": ["claude-sonnet-4", "gpt-5"], "label": "primary", "system_prompt": "", "web_tools": false, "max_output_tokens": null, "timeout_s": null }
                    ],
                    "judge": "opus",
                    "judge_system_prompt": "",
                    "judge_max_output_tokens": null,
                    "judge_timeout_s": null,
                    "judges": [
                      { "model": "opus", "label": "final", "system_prompt": "", "web_tools": false, "max_output_tokens": null, "timeout_s": null }
                    ],
                    "min_answered": 2
                  }
                ]
              }
            }|}))
  in
  Alcotest.(check string) "default preset" "consensus-3" fcfg.default_preset;
  Alcotest.(check int) "1 fusion preset" 1 (List.length fcfg.presets);
  Alcotest.(check int) "live panel group decoded" 1
    (List.length (List.hd fcfg.presets).panels);
  Alcotest.(check int) "live judge spec decoded" 1
    (List.length (List.hd fcfg.presets).judges);

  (* Surface 2: Harness health + strict 64-hex notes_hash + Verification Evidence/Summary/Specs/TLC + Activity + Runtime Trace + Keeper Logs *)
  let valid_hash =
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  in
  Alcotest.(check bool) "valid 64 lowercase hex" true
    (Wire_work.is_valid_notes_hash valid_hash);
  Alcotest.(check bool) "rejects uppercase hex" false
    (Wire_work.is_valid_notes_hash (String.uppercase_ascii valid_hash));
  Alcotest.(check bool) "rejects 63-char hex" false
    (Wire_work.is_valid_notes_hash (String.sub valid_hash 0 63));
  Alcotest.(check bool) "rejects non-hex" false
    (Wire_work.is_valid_notes_hash (String.make 64 'z'));
  let hh =
    expect_ok "decode_harness_health"
      (Wire_work.decode_harness_health
         (parse_json
            (Printf.sprintf
               {|{
                 "generated_at": 1795254000.0,
                 "scope_note": "last 7d",
                 "overview": { "evaluator_status": "healthy", "fallback_ratio": 0.05, "last_signal_at": 1795253900.0 },
                 "calibration": { "total_verdicts": 20, "approve_count": 16, "reject_count": 4, "labeled_count": 10, "false_positive_count": 1, "false_negative_count": 0, "agreement_rate": 0.90, "fallback_count": 1, "distinct_runtime_count": 2, "verdicts_with_generator_runtime": 18, "distinct_runtime_rate": 0.85, "recent_fallback_reasons": ["timeout"], "unreadable_record_count": 0 },
                 "recent_verdicts": [
                   { "timestamp": 1795253900.0, "task_id": "task-1", "task_title": "Ship Wave 3", "agent_name": "alpha", "gate": "completion", "verdict": "approve", "evaluator_runtime": "opus", "notes_hash": %S }
                 ],
                 "recent_verdicts_unreadable_count": 0
               }|}
               valid_hash)))
  in
  Alcotest.(check string) "harness evaluator_status" "healthy" hh.evaluator_status;
  Alcotest.(check string) "harness notes_hash exact" valid_hash
    (List.hd hh.recent_verdicts).notes_hash;
  let vev =
    expect_ok "decode_verification_evidence"
      (Wire_work.decode_verification_evidence
         (parse_json
            {|{
              "result": {
                "task_id": "task-1",
                "verification_id": "verif-1",
                "producer": "alpha",
                "authority_kind": "operator",
                "authority_actor": "admin",
                "evidence": {
                  "access": "available",
                  "items": [
                    { "kind": "note", "content": "All tests green" },
                    { "kind": "artifact", "reference": "report.md", "content": "# OK", "bytes": 4, "truncated": false },
                    { "kind": "artifact_unreadable", "reference": "missing.bin", "reason": { "code": "not_found", "detail": "deleted" } }
                  ]
                }
              }
            }|}))
  in
  Alcotest.(check bool) "verif evidence available" true vev.available;
  Alcotest.(check int) "3 evidence items" 3 (List.length vev.items);
  let vsum =
    expect_ok "decode_verification_summary"
      (Wire_work.decode_verification_summary
         (parse_json {|{ "updated_at": "2026-11-23T08:00:00Z", "total": 10 }|}))
  in
  Alcotest.(check int) "verif summary total" 10 vsum.total;
  Alcotest.(check (option int)) "verif summary omits unreported pending" None
    vsum.pending;
  Alcotest.(check (option int)) "verif summary omits unreported approved" None
    vsum.approved;
  Alcotest.(check (option int)) "verif summary omits unreported rejected" None
    vsum.rejected;
  let vspecs =
    expect_ok "decode_verification_specs"
      (Wire_work.decode_verification_specs
         (parse_json {|{ "updated_at": "2026-11-23T08:00:00Z", "specs_dir": "specs", "entries": [{ "name": "KeeperFSM.tla", "path": "specs/KeeperFSM.tla", "category": "keeper", "has_clean_cfg": true, "has_buggy_cfg": true, "mtime_iso": "2026-11-23T07:00:00Z" }] }|}))
  in
  Alcotest.(check int) "1 TLA spec" 1 (List.length vspecs.entries);
  let vtlc =
    expect_ok "decode_verification_tlc_results"
      (Wire_work.decode_verification_tlc_results
         (parse_json {|{ "updated_at": "2026-11-23T08:00:00Z", "results_dir": "specs/tlc", "entries": [{ "spec_name": "KeeperFSM", "cfg_name": "clean.cfg", "category": "keeper", "status": "pass", "states_explored": 4200, "distinct_states": 900, "diameter": 12 }] }|}))
  in
  Alcotest.(check int) "1 TLC result" 1 (List.length vtlc.entries);
  let act_events, next_seq =
    expect_ok "decode_activity_events_page"
      (Wire_infra.decode_activity_events_page
         (parse_json {|{ "events": [{ "seq": 10, "ts_ms": 1795254000000, "ts_iso": "2026-11-23T08:00:00Z", "kind": "turn.completed", "actor": { "id": "alpha", "kind": "keeper" }, "subject": { "id": "task-1" }, "tags": ["turn"], "payload": { "ok": true } }], "next_after_seq": 10 }|}))
  in
  Alcotest.(check int) "1 activity event" 1 (List.length act_events);
  Alcotest.(check int) "next_after_seq" 10 next_seq;
  let rtrace =
    expect_ok "decode_runtime_trace"
      (Wire_infra.decode_runtime_trace
         (parse_json {|{ "keeper": "alpha", "trace_id": "tr-9", "turn_id": 42, "health": "healthy", "manifest_total_rows": 5, "manifest_returned_rows": 5, "receipt_returned_rows": 2 }|}))
  in
  Alcotest.(check string) "runtime trace id" "tr-9" rtrace.trace_id;
  Alcotest.(check string) "keeper metrics path has NO ?limit="
    "/api/v1/keepers/alpha/metrics"
    (Wire_keeper_context.keeper_metrics_path ~keeper:"alpha");
  let kmet =
    expect_ok "decode_keeper_metrics"
      (Wire_keeper_context.decode_keeper_metrics
         (parse_json {|{ "keeper": "alpha", "scanned_rows": 50, "skipped_rows": 0, "window_summary": { "sample_points": 5, "turn_points": 3, "heartbeat_points": 2, "proactive_points": 0, "tool_call_count": 9, "top_tools": [{ "tool": "masc_board_post", "count": 4 }] }, "series": [{ "ts_unix": 1795254000.0, "trace_id": "tr-9", "channel": "reactive", "latency_ms": 840, "cost_usd": 0.02, "work_kind": "turn", "tool_call_count": 2, "tools_used": ["masc_board_post"] }] }|}))
  in
  Alcotest.(check int) "keeper metrics turn_points" 3 kmet.turn_points;
  let kslog =
    expect_ok "decode_keeper_sandbox_logs"
      (Wire_keeper_context.decode_keeper_sandbox_logs
         (parse_json {|{ "keeper": "alpha", "backend": "microvm", "state": "ok", "tail": 200, "instances": [{ "instance_id": "vm-1", "instance_name": "alpha-vm", "running": true, "stdout": "ready\n", "stderr": "" }] }|}))
  in
  Alcotest.(check int) "1 sandbox log instance" 1 (List.length kslog.instances);

  (* Surface 3: Workspace Code Browser + Git (100% live shapes + required ?path=) *)
  Alcotest.(check string) "workspace_files_path always emits path="
    "/api/v1/workspace/files?path="
    (Wire_infra.workspace_files_path ~scope:Wire_infra.Ws_project ());
  Alcotest.(check string) "workspace_search_path always emits path= (never .)"
    "/api/v1/workspace/search?path=&q=Eio&ignore_case=1"
    (Wire_infra.workspace_search_path ~scope:Wire_infra.Ws_project ~path:"."
       ~query:"Eio" ());
  Alcotest.(check string) "git_branches_path always emits path="
    "/api/v1/git/branches?path="
    (Wire_infra.git_branches_path ~scope:Wire_infra.Ws_project ());
  Alcotest.(check string) "git_worktrees_path always emits path="
    "/api/v1/git/worktrees?path="
    (Wire_infra.git_worktrees_path ~scope:Wire_infra.Ws_project ());
  let ws_nodes =
    expect_ok "decode_workspace_children (live bare array)"
      (Wire_infra.decode_workspace_children
         (parse_json {|[{ "path": "lib", "label": "lib", "depth": 0, "parent": "", "hasChildren": true, "diff": "M" }, { "path": "lib/main.ml", "label": "main.ml", "depth": 1, "parent": "lib", "hasChildren": false }]|}))
  in
  Alcotest.(check int) "2 workspace tree nodes" 2 (List.length ws_nodes);
  let ws_files =
    expect_ok "decode_workspace_files"
      (Wire_infra.decode_workspace_files
         (parse_json {|{ "root": ".", "files": ["lib/main.ml", "README.md"] }|}))
  in
  Alcotest.(check int) "2 workspace files" 2 (List.length ws_files.files);
  let ws_search =
    expect_ok "decode_workspace_search"
      (Wire_infra.decode_workspace_search
         (parse_json {|{ "root": ".", "query": "Eio", "truncated": false, "matches": [{ "path": "lib/main.ml", "line": 12, "text": "Eio_main.run" }] }|}))
  in
  Alcotest.(check int) "1 search match" 1 (List.length ws_search.matches);
  let ws_file =
    expect_ok "decode_workspace_file"
      (Wire_infra.decode_workspace_file ~path:"lib/main.ml"
         (parse_json {|{ "content": "let () = print_endline \"ok\"\n", "revision": "rev-abc123" }|}))
  in
  Alcotest.(check string) "workspace file rev" "rev-abc123" ws_file.revision;
  let g_st =
    expect_ok "decode_git_status (live upstream object)"
      (Wire_infra.decode_git_status
         (parse_json {|{ "branch": { "head": "main", "upstream": { "name": "origin/main", "ahead": 1, "behind": 0 } }, "total": 1, "changes": [{ "path": "lib/main.ml", "staged": true, "unstaged": false, "untracked": false, "conflicted": false }] }|}))
  in
  Alcotest.(check (option string)) "git status upstream decoded from object"
    (Some "origin/main") g_st.upstream;
  Alcotest.(check int) "1 git status change" 1 (List.length g_st.changes);
  let g_br =
    expect_ok "decode_git_branches"
      (Wire_infra.decode_git_branches
         (parse_json {|{ "branches": [{ "name": "main", "current": true, "upstream": { "name": "origin/main", "ahead": 1, "behind": 0 }, "commit_epoch": 1795254000, "subject": "feat: wave3" }] }|}))
  in
  Alcotest.(check int) "1 git branch" 1 (List.length g_br);
  let g_wt =
    expect_ok "decode_git_worktrees (live state=branch)"
      (Wire_infra.decode_git_worktrees
         (parse_json {|{ "worktrees": [{ "name": "main-wt", "main": true, "head": "abc1234", "state": "branch", "branch": "main", "locked": false, "prunable": false }] }|}))
  in
  Alcotest.(check int) "1 git worktree" 1 (List.length g_wt);
  let g_bl =
    expect_ok "decode_git_blame (live bare array)"
      (Wire_infra.decode_git_blame
         (parse_json {|[{ "file_path": "lib/main.ml", "line_start": 1, "line_end": 10, "keeper_id": "alpha", "timestamp_ms": 1795254000000, "kind": "edit" }]|}))
  in
  Alcotest.(check int) "1 git blame span" 1 (List.length g_bl);
  let g_log =
    expect_ok "decode_git_log"
      (Wire_infra.decode_git_log
         (parse_json {|{ "commits": [{ "hash": "abcdef123456", "timestamp_ms": 1795254000000, "author": "builder", "subject": "add code view" }] }|}))
  in
  Alcotest.(check int) "1 git log commit" 1 (List.length g_log);
  let g_diff =
    expect_ok "decode_git_diff"
      (Wire_infra.decode_git_diff
         (parse_json {|{ "has_changes": true, "unified": [{ "kind": "context", "oldLine": 1, "newLine": 1, "text": "let x = 1" }, { "kind": "add", "newLine": 2, "text": "let y = 2" }] }|}))
  in
  Alcotest.(check int) "2 git diff lines" 2 (List.length g_diff.lines);

  (* Surface 4: Memory Health, Ledger, Context, Facts Tree, Journal *)
  let mhf =
    expect_ok "decode_keeper_memory_health_fleet"
      (Wire_knowledge.decode_keeper_memory_health_fleet
         (parse_json {|{ "schema": "keeper.memory_os.current_health.v19", "generated_at": 1795254000.0, "keepers": [{ "keeper_id": "alpha", "revision": 5, "updated_at": 1795254000.0, "facts": 30, "observed_facts": 20, "derived_facts": 10, "support_invalidations": 1, "snapshot_bytes": 4096, "added": 2, "removed": 0, "snapshot_present": true, "age_bins": null, "facts_by_hour": [], "librarian_failures": 0, "vision_ingest_errors": 0, "read_error": null, "source_revision": 1, "source_facts": 3, "source_invalidations": 0, "source_snapshot_bytes": 512, "source_snapshot_present": true, "source_read_error": null, "alerts": [{ "severity": "warn", "code": "stale_digest", "target": "alpha", "label": "Stale", "message": "digest lag" }] }] }|}))
  in
  let total_facts, _, total_alerts, warn_alerts, _ =
    Wire_knowledge.memory_health_fleet_totals mhf
  in
  Alcotest.(check int) "fleet memory total_facts" 30 total_facts;
  Alcotest.(check int) "fleet memory total_alerts" 1 total_alerts;
  Alcotest.(check int) "fleet memory warn_alerts" 1 warn_alerts;
  let wml =
    expect_ok "decode_workspace_memory_ledger"
      (Wire_knowledge.decode_workspace_memory_ledger
         (parse_json {|{ "status": "available", "ledger_sha256": "deadbeef", "ledger": { "claims": [{ "claim_id": "c-1", "claim": "main is squash-only" }], "conflicts": [], "facts": [{ "current_claim": "ci passes", "source_state": "present", "disposition": { "kind": "claim", "claim_id": "c-1" } }] } }|}))
  in
  Alcotest.(check int) "1 workspace ledger claim" 1 (List.length wml.claims);
  let wmc =
    expect_ok "decode_workspace_memory_context"
      (Wire_knowledge.decode_workspace_memory_context
         (parse_json {|{ "generated_at": 1795254000.0, "discovery": { "status": "available" }, "keepers": [{ "keeper_id": "alpha", "ordinary": { "status": "available", "snapshot": { "revision": 5, "facts": [1,2] } }, "source_bound": { "status": "missing" } }] }|}))
  in
  Alcotest.(check int) "1 workspace context keeper" 1 (List.length wmc.keepers);
  let kmf =
    expect_ok "decode_keeper_memory_facts"
      (Wire_knowledge.decode_keeper_memory_facts
         (parse_json {|{ "keeper": "alpha", "ordinary": { "present": true, "revision": 5, "snapshot_sha256": "deadbeef", "updated_at": 1795254000.0, "facts": [{ "memory_id": "m-1", "claim": "use result types", "category": "fact", "origin": "authored", "first_seen": 1795250000.0, "last_seen": 1795254000.0, "basis": { "kind": "observed" }, "events": { "retrieved_count": 0, "retrieved_distinct_days": 0, "last_retrieved_at": null, "retracted_count": 0, "revised_from": [] } }], "support_invalidations": [] }, "source_bound": { "present": true, "revision": 1, "updated_at": 1795254000.0, "facts": [{ "claim": "docs contract", "path": "AGENTS.md", "first_seen": 1795250000.0, "sha256": "abc" }], "invalidations": [] }, "events_unreadable_lines": 0, "events_read_error": null }|}))
  in
  let ordinary_count =
    match kmf.ordinary with
    | Wire_knowledge.Memory_store_present om -> List.length om.facts
    | Wire_knowledge.Memory_store_absent
    | Wire_knowledge.Memory_store_read_error _ -> 0
  in
  Alcotest.(check int) "1 ordinary fact" 1 ordinary_count;
  let kmj =
    expect_ok "decode_keeper_memory_journal (live List change fields)"
      (Wire_knowledge.decode_keeper_memory_journal
         (parse_json {|{ "keeper": "alpha", "returned": 1, "undecodable_lines": 0, "entries": [{ "structural_id": "j-1", "ok": true, "outcome": "committed", "recorded_at": 1795253900.0, "revision": 5, "source": { "kind": "explicit_write", "trace_id": "tr-1" }, "change": { "added": [{ "memory_id": "m-1", "claim": "c1" }, { "memory_id": "m-2", "claim": "c2" }], "removed": [], "retained": 10, "invalidated": [{ "fact": { "memory_id": "m-0" }, "missing_premise_ids": ["p-1"] }] } }], "activity": { "events": [{ "identity": "ev-1", "recorded_at": 1795253900.0, "revision": 5, "kind": "fact_added", "before": [], "after": [{ "claim": "use result types" }] }], "notes": ["clean run"] } }|}))
  in
  Alcotest.(check int) "1 journal entry" 1 (List.length kmj.entries);
  Alcotest.(check int) "journal change.added list length = 2" 2
    (List.hd kmj.entries).added;
  Alcotest.(check int) "journal change.invalidated list length = 1" 1
    (List.hd kmj.entries).invalidated;
  Alcotest.(check int) "1 journal activity event" 1
    (List.length kmj.activity_events);

  (* Surface 5: Keeper Identity (OAuth + GitHub), Addon Package Catalog/Preview, Connector Names *)
  let op =
    expect_ok "decode_oauth_providers (live on_file)"
      (Wire_keeper_context.decode_oauth_providers
         (parse_json {|{ "callback": { "url": "http://127.0.0.1:8935/oauth/cb" }, "providers": [{ "id": "slack", "label": "Slack", "app_state": { "kind": "on_file" } }] }|}))
  in
  Alcotest.(check int) "1 oauth provider" 1 (List.length op.providers);
  let oa =
    expect_ok "decode_oauth_attached_tools (live on_file)"
      (Wire_keeper_context.decode_oauth_attached_tools
         (parse_json {|{ "keeper": "alpha", "providers": [{ "provider": "slack", "provider_label": "Slack", "attached": true, "app_state": { "kind": "on_file" }, "enabled": true, "tools": ["slack_post"] }] }|}))
  in
  Alcotest.(check int) "1 attached provider" 1 (List.length oa.providers);
  let ost =
    expect_ok "decode_oauth_attempt_status"
      (Wire_keeper_context.decode_oauth_attempt_status
         (parse_json {|{ "kind": "pending", "expires_at": 1795254600.0 }|}))
  in
  Alcotest.(check string) "oauth attempt kind" "pending" ost.kind;
  let ghi =
    expect_ok "decode_github_identity (live host_process_credential_only)"
      (Wire_keeper_context.decode_github_identity
         (parse_json {|{ "keeper": "alpha", "hostname": "github.com", "config_dir": "/tmp/gh", "projected_token_env_names": ["GH_TOKEN"], "stored": { "authenticated": true, "login": "bot-alpha", "scopes": ["repo"] }, "effective": { "authenticated": true, "login": "bot-alpha", "scopes": ["repo"] }, "effective_probe_scope": "host_process_credential_only", "checked_at_unix": 1795254000.0 }|}))
  in
  Alcotest.(check (option string)) "github login" (Some "bot-alpha") ghi.effective.login;
  let acat =
    expect_ok "decode_addon_package_catalog (live lane.toml)"
      (Wire_runtime.decode_addon_package_catalog
         (parse_json {|{ "directory": "addons", "entries": [{ "kind": "folder", "path": "addons/custom" }, { "kind": "package", "manifest_path": "addons/browser/lane.toml", "title": "Browser Lane", "revision": "1.2.0", "description": "Web automation", "ui_category": "browser" }] }|}))
  in
  Alcotest.(check int) "2 catalog entries" 2 (List.length acat.entries);
  let aprev =
    expect_ok "decode_addon_package_preview (live observe/derive/act)"
      (Wire_runtime.decode_addon_package_preview
         (parse_json {|{ "manifest_path": "addons/browser/lane.toml", "package": { "id": "browser", "revision": "1.2.0", "title": "Browser Lane", "ui_category": "browser", "exported_tools": ["browser_open"], "contributions": ["observe", "derive", "act"] }, "execution": { "kind": "host_process" } }|}))
  in
  Alcotest.(check string) "addon preview id" "browser" aprev.id;
  let cnames =
    expect_ok "decode_connector_names_page"
      (Wire_runtime.decode_connector_names_page
         (parse_json {|{ "connector_id": "slack-eng", "kind": "channel", "total": 2, "has_more": false, "mappings": [{ "id": "C01ENG", "name": "engineering" }, { "id": "C02OPS", "name": "ops" }] }|}))
  in
  Alcotest.(check int) "2 connector channel names" 2 (List.length cnames.mappings);

  (* Negative malformed decoder Error paths & Evidence_pending / Evidence_absent *)
  let mk_fusion_ev_json status =
    parse_json
      (Printf.sprintf
         {|{
           "run": {
             "run_id": "run-ev-1", "keeper": "alpha", "preset": "consensus",
             "topology": "simple", "started_at": 1795253000.0,
             "status": "completed", "stage": "done"
           },
           "evidence": { "status": %S }
         }|}
         status)
  in
  let fdet_pending =
    expect_ok "decode_fusion_run_detail Evidence_pending"
      (Wire_runtime.decode_fusion_run_detail (mk_fusion_ev_json "pending"))
  in
  Alcotest.(check bool) "fusion evidence status=pending decodes Evidence_pending" true
    (match fdet_pending.evidence with
    | Wire_runtime.Evidence_pending -> true
    | Wire_runtime.Evidence_recorded _ | Wire_runtime.Evidence_absent -> false);
  let fdet_absent =
    expect_ok "decode_fusion_run_detail Evidence_absent"
      (Wire_runtime.decode_fusion_run_detail (mk_fusion_ev_json "absent"))
  in
  Alcotest.(check bool) "fusion evidence status=absent decodes Evidence_absent" true
    (match fdet_absent.evidence with
    | Wire_runtime.Evidence_absent -> true
    | Wire_runtime.Evidence_recorded _ | Wire_runtime.Evidence_pending -> false);
  ignore
    (expect_err "fusion evidence unknown status rejected"
       (Wire_runtime.decode_fusion_run_detail (mk_fusion_ev_json "unknown_status"))
      : string);
  ignore
    (expect_err "decode_verification_evidence missing evidence rejected"
       (Wire_work.decode_verification_evidence
          (parse_json {|{ "result": { "task_id": "t1", "verification_id": "v1" } }|}))
      : string);
  ignore
    (expect_err "decode_verification_evidence unknown item kind rejected"
       (Wire_work.decode_verification_evidence
          (parse_json
             {|{ "result": { "task_id": "t1", "verification_id": "v1", "evidence": { "access": "available", "items": [{ "kind": "mystery" }] } } }|}))
      : string);
  ignore
    (expect_err "decode_harness_health malformed non-object rejected"
       (Wire_work.decode_harness_health (parse_json "[]"))
      : string);
  ignore
    (expect_err "decode_workspace_file missing content rejected"
       (Wire_infra.decode_workspace_file ~path:"a.ml" (parse_json {|{ "revision": "r1" }|}))
      : string);
  ignore
    (expect_err "decode_github_identity malformed non-object rejected"
       (Wire_keeper_context.decode_github_identity (parse_json "42"))
      : string)

let test_ui_bus_concurrent_no_lost_wakeup () =
  (* P0-1 regression: cross-domain publish_stream/publish_snapshot + drain_up_to
     must NEVER leave wake_pending = true with an empty bus. *)
  let bell = Atomic.make false in
  let wake_count = Atomic.make 0 in
  let bus =
    Ui_bus.create ~stream_capacity:64 ~key_equal:String.equal
      ~key_hash:Hashtbl.hash
      ~on_wake:(fun () ->
        Atomic.set bell true;
        Atomic.incr wake_count)
      ()
  in
  (* 1. Deterministic partial-drain re-arming & empty-drain wake_pending reset *)
  Ui_bus.publish_stream bus 1;
  Ui_bus.publish_stream bus 2;
  Alcotest.(check bool) "initial publish rings bell" true (Atomic.get bell);
  Atomic.set bell false;
  let first = Ui_bus.drain_up_to ~max_items:1 bus in
  Alcotest.(check int) "partial drain takes 1 item" 1 (List.length first);
  Alcotest.(check bool) "partial drain with more items re-rings bell" true
    (Atomic.get bell);
  Atomic.set bell false;
  let second = Ui_bus.drain_up_to ~max_items:4 bus in
  Alcotest.(check int) "second drain takes remaining 1 item" 1
    (List.length second);
  Alcotest.(check bool) "bus empty after full drain" true (Ui_bus.is_empty bus);
  Alcotest.(check bool) "full drain does not spuriously ring bell" false
    (Atomic.get bell);
  Ui_bus.publish_snapshot bus ~key:"k" 42;
  Alcotest.(check bool) "next publish after full drain rings bell" true
    (Atomic.get bell);
  ignore (Ui_bus.drain bus : (string, int, int) Ui_bus.item list);
  Atomic.set bell false;

  (* 2. Cross-domain stress interleaving publish_* (Domain 2) vs drain_up_to
     (Domain 1), simulating app.ml's Wake_bell.drain_mask + drain_bus loop. *)
  let producer_done = Atomic.make false in
  let producer =
    Domain.spawn (fun () ->
        for i = 1 to 4000 do
          if i mod 3 = 0 then Ui_bus.publish_snapshot bus ~key:"snap" i
          else Ui_bus.publish_stream bus i;
          if i mod 17 = 0 then Domain.cpu_relax ()
        done;
        Atomic.set producer_done true)
  in
  let drained_total = ref 0 in
  let rec consume () =
    Atomic.set bell false;
    let batch = Ui_bus.drain_up_to ~max_items:8 bus in
    drained_total := !drained_total + List.length batch;
    if Atomic.get producer_done && Ui_bus.is_empty bus then begin
      (* One final drain_up_to guarantees wake_pending = false under t.mu. *)
      let tail = Ui_bus.drain_up_to ~max_items:32 bus in
      drained_total := !drained_total + List.length tail
    end
    else begin
      if batch = [] then Domain.cpu_relax ();
      consume ()
    end
  in
  consume ();
  Domain.join producer;
  Alcotest.(check bool) "drained items across domains" true (!drained_total > 0);
  Alcotest.(check bool) "bus is empty at quiescence" true (Ui_bus.is_empty bus);
  (* Critical P0-1 assertion: if wake_pending were stuck true while bus is empty,
     this fresh publish would NOT fire on_wake! *)
  Atomic.set bell false;
  Ui_bus.publish_stream bus 999_999;
  Alcotest.(check bool) "fresh stream publish after concurrent drain wakes UI"
    true (Atomic.get bell);
  ignore (Ui_bus.drain_up_to ~max_items:32 bus : (string, int, int) Ui_bus.item list);
  Atomic.set bell false;
  Ui_bus.publish_snapshot bus ~key:"after" 1;
  Alcotest.(check bool) "fresh snapshot publish after concurrent drain wakes UI"
    true (Atomic.get bell);
  ignore (Ui_bus.drain bus : (string, int, int) Ui_bus.item list)

let test_timeout_diagnostics_and_sanitization () =
  (* 1. sanitize_timeout_path strips query strings & fragments cleanly *)
  Alcotest.(check string) "strip query string"
    "/api/v1/dashboard/tools"
    (Http_client.sanitize_timeout_path
       "/api/v1/dashboard/tools?token=secret&limit=20");
  Alcotest.(check string) "strip fragment"
    "/api/v1/dashboard/tools"
    (Http_client.sanitize_timeout_path "/api/v1/dashboard/tools#frag");
  Alcotest.(check string) "strip query + fragment"
    "/api/v1/keepers/alpha/chat/stream"
    (Http_client.sanitize_timeout_path
       "  /api/v1/keepers/alpha/chat/stream?token=secret&limit=20#frag  ");
  Alcotest.(check string) "strip fragment before query"
    "/api/v1/board"
    (Http_client.sanitize_timeout_path "/api/v1/board#sec?token=secret");
  Alcotest.(check string) "preserve clean path"
    "/api/v1/infra/sandboxes"
    (Http_client.sanitize_timeout_path "/api/v1/infra/sandboxes");
  Alcotest.(check string) "query-only becomes empty"
    ""
    (Http_client.sanitize_timeout_path "?token=secret");
  Alcotest.(check string) "fragment-only becomes empty"
    ""
    (Http_client.sanitize_timeout_path "#frag");
  Alcotest.(check string) "empty and whitespace become empty"
    ""
    (Http_client.sanitize_timeout_path "   \t\r\n  ");
  Alcotest.(check string) "full http URL strips host and query"
    "/api/v1/tools"
    (Http_client.sanitize_timeout_path "http://host:8935/api/v1/tools?token=abc");
  Alcotest.(check string) "https URL with userinfo strips credentials, query and fragment"
    "/api/v1/tools"
    (Http_client.sanitize_timeout_path
       "https://user:s3cr3t@host:8443/api/v1/tools?token=abc#frag");
  Alcotest.(check string) "pathless URL with userinfo returns empty (zero credential leak)"
    ""
    (Http_client.sanitize_timeout_path
       "https://user:s3cr3t@host:8443?token=abc");
  Alcotest.(check string) "root-only URL with userinfo returns slash"
    "/"
    (Http_client.sanitize_timeout_path "https://user:s3cr3t@host:8443/?token=abc");
  Alcotest.(check string) "protocol-relative URL strips userinfo and host"
    "/api/v1/tools"
    (Http_client.sanitize_timeout_path "//user:s3cr3t@host/api/v1/tools");
  Alcotest.(check string) "pathless protocol-relative URL returns empty"
    ""
    (Http_client.sanitize_timeout_path "//user:s3cr3t@host?token=abc");
  Alcotest.(check string) "custom RFC 3986 scheme strips authority"
    "/api/v1/tools"
    (Http_client.sanitize_timeout_path "masc+http-1.0://user:pass@host/api/v1/tools#f");
  Alcotest.(check string) "ASCII control bytes stripped from path and URL"
    "/api/v1/tools/clean"
    (Http_client.sanitize_timeout_path
       "https://user\r\n:pass@host/api/v1/\x1btools\x00/clean\r\n\x7f?token=abc");

  (* 2. Health.is_timeout, equal_timeout_phase, equal_transport_error *)
  Alcotest.(check bool) "Health.Timeout is_timeout" true
    (Health.is_timeout Health.Timeout);
  let all_phases =
    [
      Health.Timeout_connect;
      Health.Timeout_connect_cooldown;
      Health.Timeout_response;
      Health.Timeout_stream_header;
      Health.Timeout_stream_idle;
    ]
  in
  List.iter
    (fun phase ->
      let err =
        Health.Timeout_detail
          { phase; after_sec = Some 5.0; path = Some "/api/v1/test" }
      in
      Alcotest.(check bool) "Timeout_detail is_timeout" true
        (Health.is_timeout err);
      Alcotest.(check bool) "equal_timeout_phase reflexive" true
        (Health.equal_timeout_phase phase phase);
      Alcotest.(check bool) "equal_transport_error reflexive" true
        (Health.equal_transport_error err err);
      Alcotest.(check bool) "Timeout_detail distinct from legacy Timeout" false
        (Health.equal_transport_error err Health.Timeout))
    all_phases;
  Alcotest.(check bool) "Connect_refused not timeout" false
    (Health.is_timeout Health.Connect_refused);
  Alcotest.(check bool) "Http_status 504 not transport timeout" false
    (Health.is_timeout (Health.Http_status 504));
  Alcotest.(check bool) "Stream_eof not timeout" false
    (Health.is_timeout Health.Stream_eof);
  Alcotest.(check bool) "Other_io not timeout" false
    (Health.is_timeout (Health.Other_io "timeout"));
  Alcotest.(check bool) "distinct phases not equal" false
    (Health.equal_timeout_phase Health.Timeout_connect Health.Timeout_response);

  (* 3. All 5 Pool failure variants map accurately & sanitize paths *)
  let origin : Masc_http_client.Pool.origin =
    { scheme = "http"; host = "127.0.0.1"; port = 8935 }
  in
  let check_te label expected actual =
    Alcotest.(check bool) label true
      (Health.equal_transport_error expected actual)
  in
  let te_connect =
    Http_client.transport_error_of_failure
      ~path:"/api/v1/dashboard/tools?token=secret&limit=20#frag"
      (Masc_http_client.Request_failed
         (Masc_http_client.Pool.Connect_failed
            {
              origin;
              failure = Masc_http_client.Pool.Establishment_timeout;
              retry = Masc_http_client.Pool.Retry_in 5.0;
            }))
  in
  check_te "Connect_failed Establishment_timeout"
    (Health.Timeout_detail
       {
         phase = Health.Timeout_connect;
         after_sec = Some 5.0;
         path = Some "/api/v1/dashboard/tools";
       })
    te_connect;

  let te_cooldown =
    Http_client.transport_error_of_failure
      ~path:"/api/v1/infra/sandboxes?token=secret"
      (Masc_http_client.Request_failed
         (Masc_http_client.Pool.Connect_held_back
            {
              origin;
              failure = Masc_http_client.Pool.Establishment_timeout;
              retry_in_seconds = 5.0;
            }))
  in
  check_te "Connect_held_back Establishment_timeout (5.0s)"
    (Health.Timeout_detail
       {
         phase = Health.Timeout_connect_cooldown;
         after_sec = Some 5.0;
         path = Some "/api/v1/infra/sandboxes";
       })
    te_cooldown;

  let te_cooldown_rem =
    Http_client.transport_error_of_failure ~path:"/api/v1/infra/sandboxes"
      (Masc_http_client.Request_failed
         (Masc_http_client.Pool.Connect_held_back
            {
              origin;
              failure = Masc_http_client.Pool.Establishment_timeout;
              retry_in_seconds = 2.4;
            }))
  in
  check_te "Connect_held_back preserves remaining retry_in_seconds"
    (Health.Timeout_detail
       {
         phase = Health.Timeout_connect_cooldown;
         after_sec = Some 2.4;
         path = Some "/api/v1/infra/sandboxes";
       })
    te_cooldown_rem;

  let te_response =
    Http_client.transport_error_of_failure ~streaming:false
      ~path:"/api/v1/dashboard/tools?keeper=alpha"
      (Masc_http_client.Request_failed
         (Masc_http_client.Pool.Timed_out { after_seconds = 30.0 }))
  in
  check_te "Timed_out non-streaming -> Timeout_response"
    (Health.Timeout_detail
       {
         phase = Health.Timeout_response;
         after_sec = Some 30.0;
         path = Some "/api/v1/dashboard/tools";
       })
    te_response;

  let te_stream_hdr =
    Http_client.transport_error_of_failure ~streaming:true
      ~path:"/api/v1/keepers/chat/stream?token=secret"
      (Masc_http_client.Request_failed
         (Masc_http_client.Pool.Timed_out { after_seconds = 45.0 }))
  in
  check_te "Timed_out streaming -> Timeout_stream_header"
    (Health.Timeout_detail
       {
         phase = Health.Timeout_stream_header;
         after_sec = Some 45.0;
         path = Some "/api/v1/keepers/chat/stream";
       })
    te_stream_hdr;

  let te_stream_idle =
    Http_client.transport_error_of_failure ~streaming:true
      ~path:"/mcp?sse_kind=observer&token=secret#frag"
      (Masc_http_client.Request_failed
         (Masc_http_client.Pool.Idle_timed_out { after_seconds = 120.0 }))
  in
  check_te "Idle_timed_out -> Timeout_stream_idle"
    (Health.Timeout_detail
       {
         phase = Health.Timeout_stream_idle;
         after_sec = Some 120.0;
         path = Some "/mcp";
       })
    te_stream_idle;

  (* Non-timeout connect failures stay Connect_refused *)
  check_te "Connect_held_back Tcp_failure stays Connect_refused"
    Health.Connect_refused
    (Http_client.transport_error_of_failure ~path:"/health"
       (Masc_http_client.Request_failed
          (Masc_http_client.Pool.Connect_held_back
             {
               origin;
               failure = Masc_http_client.Pool.Tcp_failure (Failure "refused");
               retry_in_seconds = 3.0;
             })));

  (* 4. KO & EN formatting + http_error_to_string + None omissions *)
  let check_fmt label phase after_sec path exp_ko exp_en =
    let say = Health.timeout_detail_say ~phase ~after_sec ~path in
    Alcotest.(check string) (label ^ " KO") exp_ko (Say.resolve Say.Lang_ko say);
    Alcotest.(check string) (label ^ " EN") exp_en (Say.resolve Say.Lang_en say);
    let err =
      Http_client.Transport (Health.Timeout_detail { phase; after_sec; path })
    in
    Alcotest.(check string) (label ^ " http_error_to_string") exp_en
      (Http_client.http_error_to_string err)
  in
  check_fmt "connect" Health.Timeout_connect (Some 5.0)
    (Some "/api/v1/dashboard/tools")
    "연결 시간 초과 (5.0s · /api/v1/dashboard/tools)"
    "Connect timed out (5.0s · /api/v1/dashboard/tools)";
  check_fmt "cooldown" Health.Timeout_connect_cooldown (Some 5.0)
    (Some "/api/v1/infra/sandboxes")
    "연결 쿨다운 대기 중 (5.0s · /api/v1/infra/sandboxes)"
    "Connect cooldown active (5.0s · /api/v1/infra/sandboxes)";
  check_fmt "response" Health.Timeout_response (Some 30.0)
    (Some "/api/v1/dashboard/tools")
    "응답 시간 초과 (30.0s · /api/v1/dashboard/tools)"
    "Response timed out (30.0s · /api/v1/dashboard/tools)";
  check_fmt "stream_header" Health.Timeout_stream_header (Some 45.0)
    (Some "/api/v1/keepers/chat/stream")
    "스트림 응답 대기 초과 (45.0s · /api/v1/keepers/chat/stream)"
    "Stream header timed out (45.0s · /api/v1/keepers/chat/stream)";
  check_fmt "stream_idle" Health.Timeout_stream_idle (Some 120.0) (Some "/mcp")
    "스트림 유휴 시간 초과 (120.0s · /mcp)"
    "Stream idle timed out (120.0s · /mcp)";
  check_fmt "omit path" Health.Timeout_response (Some 12.0) None
    "응답 시간 초과 (12.0s)" "Response timed out (12.0s)";
  check_fmt "omit seconds" Health.Timeout_connect None (Some "/health")
    "연결 시간 초과 (/health)" "Connect timed out (/health)";
  check_fmt "omit both" Health.Timeout_stream_idle None None
    "스트림 유휴 시간 초과" "Stream idle timed out";
  Alcotest.(check string) "legacy Health.Timeout preserved" "request timed out"
    (Http_client.http_error_to_string (Http_client.Transport Health.Timeout));

  (* 5. End-to-end loopback timeout test on real Io_domain + Pool:
     proves send_raw -> Timeout_response and post_stream ?header_timeout_sec ->
     Timeout_stream_header with sanitized path (no leaked query/fragment). *)
  Eio_main.run @@ fun env ->
  Eio.Time.with_timeout_exn env#clock 5.0 @@ fun () ->
  try
    Eio.Switch.run @@ fun sw ->
    let clock = Eio.Stdenv.clock env in
    let listener =
      Eio.Net.listen ~sw ~backlog:4 env#net
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
    in
    let port =
      match Eio.Net.listening_addr listener with
      | `Tcp (_, p) -> p
      | `Unix _ -> Alcotest.fail "expected TCP listener"
    in
    Eio.Fiber.fork_daemon ~sw (fun () ->
        let rec accept_loop () =
          let flow, _ = Eio.Net.accept ~sw listener in
          Eio.Fiber.fork ~sw (fun () ->
              try
                let br = Eio.Buf_read.of_flow flow ~max_size:4096 in
                ignore (Eio.Buf_read.line br : string);
                Eio.Time.sleep clock 4.0;
                Eio.Flow.close flow
              with
              | Eio.Cancel.Cancelled _ as ex -> raise ex
              | _ -> ());
          accept_loop ()
        in
        accept_loop ());
    let io = Io_domain.start ~sw ~env in
    let ep = Http_client.make_endpoint ~host:"127.0.0.1" ~port () in
    (match
       Http_client.get_raw ~io ~clock ~timeout_sec:0.08 ep
         ~path:"/api/v1/dashboard/tools?token=secret#frag"
     with
    | Error
        (Http_client.Transport
           (Health.Timeout_detail
              {
                phase = Health.Timeout_response;
                after_sec = Some s;
                path = Some p;
              })) ->
        Alcotest.(check (float 0.01)) "response timeout sec" 0.08 s;
        Alcotest.(check string) "sanitized response path"
          "/api/v1/dashboard/tools" p
    | Error err ->
        Alcotest.failf "expected Timeout_response, got %s"
          (Http_client.http_error_to_string err)
    | Ok _ -> Alcotest.fail "expected response timeout error");
    let t_start = Clock.Mono.now () in
    (match
       Http_client.post_stream ~io ~clock ~idle_timeout_sec:5.0
         ~header_timeout_sec:0.08 ~content_type:"application/json" ~body:"{}"
         ~on_response:(fun ~status:_ ~headers:_ -> ())
         ~on_chunk:(fun _ -> ())
         ep ~path:"/api/v1/keepers/chat/stream?token=secret#frag"
     with
    | Error
        (Http_client.Transport
           (Health.Timeout_detail
              {
                phase = Health.Timeout_stream_header;
                after_sec = Some s;
                path = Some p;
              })) ->
        let elapsed = Clock.Mono.seconds_since (Clock.Mono.now ()) ~since:t_start in
        Alcotest.(check (float 0.01)) "stream header timeout sec" 0.08 s;
        Alcotest.(check string) "sanitized stream path"
          "/api/v1/keepers/chat/stream" p;
        Alcotest.(check bool)
          (Printf.sprintf "header_timeout_sec enforced quickly (%.3fs < 1.5s)"
             elapsed)
          true (elapsed < 1.5)
    | Error err ->
        Alcotest.failf "expected Timeout_stream_header, got %s"
          (Http_client.http_error_to_string err)
    | Ok () -> Alcotest.fail "expected stream header timeout error");
    Eio.Switch.fail sw Exit
  with Exit -> ()

let test_wave4_layer1_wire_codecs () =
  (* 1. AG-UI retry, checkpoint, native tool progress, stream protocol error *)
  let retry =
    expect_ok "decode KEEPER_PROVIDER_RETRY"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{
              "type": "CUSTOM",
              "runId": "keeper-operation-run-op-1",
              "name": "KEEPER_PROVIDER_RETRY",
              "value": {
                "attempt": { "routing_run_id": "r1", "runtime_id": "claude-main", "lane_attempt_index": 1 },
                "retry": { "observation_id": "o1", "attempt": 2, "max_retries": 4, "retry_delay_ms": 1500, "error_status": 429 }
              }
            }|}))
  in
  (match retry with
  | Wire_fleet.Chunk_provider_retry
      {
        operation_id = Some "op-1";
        runtime_id = Some "claude-main";
        attempt = 2;
        max_retries = 4;
        retry_delay_ms = 1500;
        error_status = Some 429;
      } ->
      ()
  | _ -> Alcotest.fail "expected Chunk_provider_retry");
  let ckpt =
    expect_ok "decode KEEPER_CONTINUATION_CHECKPOINT"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{
              "type": "CUSTOM",
              "runId": "keeper-operation-run-op-1",
              "name": "KEEPER_CONTINUATION_CHECKPOINT",
              "value": { "message": "saved after tool batch", "request_id": "req-7" }
            }|}))
  in
  (match ckpt with
  | Wire_fleet.Chunk_continuation_checkpoint
      {
        operation_id = Some "op-1";
        message = "saved after tool batch";
        request_id = Some "req-7";
      } ->
      ()
  | _ -> Alcotest.fail "expected Chunk_continuation_checkpoint");
  let prog =
    expect_ok "decode KEEPER_NATIVE_TOOL_PROGRESS"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{
              "type": "CUSTOM",
              "runId": "keeper-operation-run-op-1",
              "name": "KEEPER_NATIVE_TOOL_PROGRESS",
              "value": {
                "toolStreamScope": 1,
                "toolCallBlockIndex": 0,
                "toolCallId": "tc-9",
                "toolCallName": "Bash",
                "progress": { "kind": "output_observed", "byte_count": 512 }
              }
            }|}))
  in
  (match prog with
  | Wire_fleet.Chunk_native_tool_progress
      {
        operation_id = Some "op-1";
        tool_use_id = "scope-1-block-0";
        tool_name = Some "Bash";
        progress_label = "512B out";
      } ->
      ()
  | _ -> Alcotest.fail "expected Chunk_native_tool_progress");
  (* 2. Turn Flow decoder validates exact turn identity and decodes intake + outcomes *)
  let flow =
    expect_ok "decode_turn_flow observed"
      (Wire_keeper_context.decode_turn_flow ~keeper:"alpha" ~trace_id:"tr-1"
         ~turn_id:4
         (parse_json
            {|{
              "keeper": "alpha",
              "trace_id": "tr-1",
              "turn_id": 4,
              "manifest_total_rows": 2,
              "manifest_total_rows_exact": true,
              "manifest_scan_diagnostics": {
                "schema": "keeper.runtime_manifest_scan_diagnostics.v1",
                "unsupported_event_count": 0,
                "unsupported_event_counts": [],
                "invalid_manifest_row_count": 0,
                "invalid_json_row_count": 0,
                "unsupported_event_unattributed_count": 0,
                "samples": []
              },
              "runtime_lens": { "axes": { "lifecycle": { "turn_started_count": 1 } } },
              "manifest_rows": [
                {
                  "keeper_name": "alpha",
                  "trace_id": "tr-1",
                  "keeper_turn_id": 4,
                  "event": "turn_started",
                  "status": "ok",
                  "runtime_id": "claude-main",
                  "decision": {
                    "channel": "direct",
                    "routing_action": "dispatch",
                    "routing_reason": "primary",
                    "intake_sources": [
                      {
                        "stimulus_id": "stim-1",
                        "source_kind": "chat",
                        "source_snapshot_ref": "snap-1",
                        "admitted_revision": "rev-1",
                        "first_admitted_at": 1795252000.0
                      }
                    ]
                  }
                }
              ],
              "source_outcomes": {
                "schema": "masc.keeper.turn-source-outcomes/v1",
                "state": "observed",
                "observed_at": 1795252005.0,
                "coverage": {
                  "state": "read",
                  "rows_inspected": 1,
                  "invalid_json_rows": 0,
                  "invalid_ledger_rows": 0,
                  "storage_error": false
                },
                "sources": [
                  {
                    "stimulus_id": "stim-1",
                    "source_snapshot_ref": "snap-1",
                    "admitted_revision": "rev-1",
                    "receipts": [
                      {
                        "transition_id": "tx-1",
                        "event_id": "ev-1",
                        "applied_at": 1795252004.0,
                        "kind": "ack_turn_completed"
                      }
                    ]
                  }
                ]
              }
            }|}))
  in
  (match flow.intake with
  | Wire_keeper_context.Intake_observed { channel = Some "direct"; sources = [ s ] } ->
      Alcotest.(check string) "stimulus_id" "stim-1" s.stimulus_id
  | _ -> Alcotest.fail "expected Intake_observed");
  ignore
    (expect_err "decode_turn_flow rejects wrong turn_id"
       (Wire_keeper_context.decode_turn_flow ~keeper:"alpha" ~trace_id:"tr-1"
          ~turn_id:99
          (parse_json {|{"keeper":"alpha","trace_id":"tr-1","turn_id":4}|}))
      : string);
  (* 3. Checkpoints inventory + purge + operator note + directive/clear encoders *)
  let inv =
    expect_ok "decode_keeper_checkpoints_inventory"
      (Wire_keeper_context.decode_keeper_checkpoints_inventory
         (parse_json
            {|{
              "keeper": "alpha",
              "trace_id": "tr-1",
              "current_status": "available",
              "current": {
                "snapshot_id": "tr-1.json",
                "source_kind": "agent_core_current",
                "is_current": true,
                "status": "available",
                "message_count": 42,
                "file_stat": { "size_bytes": 8192, "mtime": 1795252000.0 }
              },
              "current_error": null,
              "history": [],
              "history_errors": []
            }|}))
  in
  Alcotest.(check string) "ckpt status" "available" inv.current_status;
  let del_res =
    expect_ok "decode_checkpoint_delete_result server keys"
      (Wire_keeper_context.decode_checkpoint_delete_result
         (parse_json
            {|{
              "deleted_snapshot_ids": ["snap-1", "snap-2"],
              "missing_snapshot_ids": ["snap-missing"],
              "refused_snapshot_ids": ["snap-cur"],
              "failed_snapshot_ids": []
            }|}))
  in
  Alcotest.(check (list string)) "deleted_snapshot_ids" [ "snap-1"; "snap-2" ]
    del_res.deleted;
  Alcotest.(check (list string)) "missing_snapshot_ids" [ "snap-missing" ]
    del_res.missing;
  Alcotest.(check (list string)) "refused_snapshot_ids" [ "snap-cur" ]
    del_res.refused;
  let note =
    expect_ok "decode_keeper_operator_note"
      (Wire_keeper_context.decode_keeper_operator_note
         (parse_json
            {|{
              "keeper": "alpha",
              "pending": true,
              "note": {
                "text": "focus on P0",
                "created_at": 1795252000.0,
                "created_by": "admin",
                "consumed_at": null,
                "consumed_turn": null
              }
            }|}))
  in
  Alcotest.(check bool) "note pending" true note.pending;
  let ws : Wire_work.expected_workspace =
    { base_path = "/tmp/ws"; masc_root = "/tmp/ws/.masc" }
  in
  let dir_json =
    Wire_keeper_context.encode_keeper_directive_body ~expected_workspace:ws
      (Wire_keeper_context.Directive_resume { operator_operation_id = "op-uuid-1" })
    |> Yojson.Safe.to_string
  in
  Alcotest.(check bool) "resume body carries operator_operation_id" true
    (String.length dir_json > 0
     && Wire_common.has_field (parse_json dir_json) "operator_operation_id"
     && Wire_common.has_field (parse_json dir_json) "expected_workspace")

let test_wave4_layer2_wire_codecs () =
  (* 1. Full Gate snapshot: pending + retry_meta + rules + recent_resolved (server ts/keeper/tool) + hitl *)
  let snap =
    expect_ok "decode_gate_snapshot full"
      (Wire_work.decode_gate_snapshot
         (parse_json
            {|{
              "generated_at": "2026-11-24T09:00:00Z",
              "approval_queue_state": { "state": "ready" },
              "approval_queue": [
                {
                  "id": "appr-1",
                  "keeper_name": "alpha",
                  "tool_name": "Bash",
                  "input_hash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                  "sequence": 3,
                  "requested_at": 1795250000.0,
                  "waiting_s": 12.5,
                  "input_preview": "{\"cmd\":\"git push\"}",
                  "phase": "blocked",
                  "exact_attempt": { "state": "unbound" },
                  "summary_attempt_disposition": { "code": "identity_unbound", "operator_detail": "No prior attempt" },
                  "summary_status": {
                    "status": "available",
                    "summary": {
                      "context_summary": "Pushes feature branch",
                      "judgment": "require_human"
                    }
                  }
                }
              ],
              "approval_rules_state": { "state": "ready" },
              "approval_rules": [
                {
                  "id": "rule-1",
                  "keeper_name": "alpha",
                  "tool_name": "Bash",
                  "request_fingerprint": "fp-abc",
                  "created_at": 1795240000.0,
                  "created_by": "admin",
                  "source_approval_id": "appr-0",
                  "expires_at": null
                }
              ],
              "recent_resolved_state": { "state": "ready" },
              "recent_resolved": [
                {
                  "ts": 1795249000.0,
                  "event": "resolved",
                  "id": "appr-0",
                  "keeper": "alpha",
                  "tool": "Bash",
                  "decision": "approve",
                  "decision_kind": "approve",
                  "decision_reason": null,
                  "decision_source": "human_operator",
                  "authorization_source": "one_shot_resolution",
                  "actor": "admin"
                }
              ],
              "hitl": {
                "gate_mode": { "mode": "auto_judge", "configured": true, "state": "ready" },
                "external_gate_mode": { "mode": "manual", "configured": false, "state": "ready" },
                "judge_lane": { "status": "available", "lane_id": "exact/hitl_summary", "slots": ["slot-a"] }
              }
            }|}))
  in
  Alcotest.(check int) "gate pending count" 1 (List.length snap.pending);
  Alcotest.(check int) "gate retry_meta count" 1 (List.length snap.retry_meta);
  Alcotest.(check int) "gate rules count" 1 (List.length snap.rules);
  Alcotest.(check int) "gate recent_resolved count" 1 (List.length snap.recent_resolved);
  let rm = List.hd snap.retry_meta in
  Alcotest.(check (option string)) "summary_judgment" (Some "require_human") rm.summary_judgment;
  let ws : Wire_work.expected_workspace =
    { base_path = "/tmp/ws"; masc_root = "/tmp/ws/.masc" }
  in
  let res_body =
    Wire_work.encode_gate_resolution_with_policy ~id:"appr-1" ~approved:true
      ~reason:None ~remember_rule:true ~rule_expires_at:1800000000.0
      ~expected_workspace:ws ()
  in
  Alcotest.(check bool) "remember_rule encoded" true
    (Wire_common.has_field res_body "remember_rule"
     && Wire_common.has_field res_body "rule_expires_at"
     && Wire_common.has_field res_body "expected_workspace");
  let retry_body = Wire_work.encode_gate_retry ~expected_workspace:ws rm in
  Alcotest.(check bool) "retry closed fields" true
    (Wire_common.has_field retry_body "input_hash"
     && Wire_common.has_field retry_body "sequence"
     && Wire_common.has_field retry_body "exact_attempt"
     && Wire_common.has_field retry_body "summary_attempt_disposition");
  (* 2. Tool approval modes + late approval attempts + ack_uncertain + gate tool events *)
  let modes =
    expect_ok "decode_tool_approval_modes"
      (Wire_work.decode_tool_approval_modes
         (parse_json
            {|{"overrides":[{"keeper":"alpha","mode":"yolo"}],"default":"auto","restore_error":null}|}))
  in
  Alcotest.(check int) "1 override" 1 (List.length modes.overrides);
  let attempts =
    expect_ok "decode_late_approval_attempts"
      (Wire_work.decode_late_approval_attempts
         (parse_json
            {|{"ok":true,"attempts":[{"consume_id":"c-1","keeper_name":"alpha","tool_name":"Bash","args_fingerprint":"fp-1","consumed_at":1795250000.0,"outcome":"unknown"}]}|}))
  in
  Alcotest.(check int) "1 late attempt" 1 (List.length attempts);
  let ack_body =
    Wire_work.encode_hitl_ack_uncertain ~keeper_name:"alpha" ~consume_id:"c-1"
  in
  (match ack_body with
   | `Assoc fields -> Alcotest.(check int) "ack_uncertain exact 3 fields" 3 (List.length fields)
   | _ -> Alcotest.fail "expected object");
  let gte =
    expect_ok "decode_gate_tool_events"
      (Wire_work.decode_gate_tool_events
         (parse_json
            {|{
              "generated_at": "2026-11-24T09:00:00Z",
              "window_minutes": 60,
              "tool_rejections": [{ "tool": "Bash", "reason": "policy", "count": 4 }],
              "approval_queue_state": { "state": "ready" },
              "approval_queue": { "depth": 2, "p50_wait_sec": 3.5, "p95_wait_sec": 10.0, "oldest_pending_sec": 12.0 }
            }|}))
  in
  Alcotest.(check int) "gate tool_rejections" 1 (List.length gte.tool_rejections);
  (* 3. Tool Quality + Keeper Waiting Inventory + Stateless MCP 2026-07-28 *)
  let tq =
    expect_ok "decode_tool_quality"
      (Wire_runtime.decode_tool_quality
         (parse_json
            {|{
              "generated_at": "2026-11-24T09:00:00Z",
              "sampling_mode": "recent_n",
              "total": 100,
              "success": 92,
              "failure": 8,
              "deferred": 1,
              "unsettled": 0,
              "malformed": 0,
              "success_rate": 92.0,
              "by_tool": [{ "name": "masc_status", "calls": 40, "success_pct": 100.0, "avg_ms": 12.5, "output_truncated_count": 0, "avg_output_chars": 250.0 }],
              "by_keeper": [{ "name": "alpha", "calls": 60, "success_pct": 95.0 }],
              "by_runtime": [{ "name": "claude-main", "calls": 100, "success_pct": 92.0 }],
              "failure_categories": [{ "category": "timeout", "count": 5 }]
            }|}))
  in
  Alcotest.(check int) "tool quality total" 100 tq.total;
  let tool_quality_fields =
    [
      ("generated_at", `String "2026-11-24T09:00:00Z");
      ("total", `Int 1);
      ("success", `Int 1);
      ("failure", `Int 0);
      ("success_rate", `Float 100.);
    ]
  in
  let decoded_without_sampling_mode =
    expect_ok "decode_tool_quality without sampling mode"
      (Wire_runtime.decode_tool_quality (`Assoc tool_quality_fields))
  in
  Alcotest.(check string) "missing sampling mode defaults to recent_n"
    "recent_n" decoded_without_sampling_mode.sampling_mode;
  (match
     Wire_runtime.decode_tool_quality
       (`Assoc (("sampling_mode", `Int 1) :: tool_quality_fields))
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "non-string sampling mode must fail to decode");
  let wi =
    expect_ok "decode_keeper_waiting_inventory"
      (Wire_runtime.decode_keeper_waiting_inventory
         (parse_json
            {|{
              "schema": "masc.dashboard.keeper_waiting_inventory.v4",
              "keeper_count": 1,
              "waiting_keeper_count": 1,
              "row_count": 1,
              "total_row_count": 1,
              "oldest_age_seconds": 15.0,
              "rows": [{ "keeper_name": "alpha", "source": "hitl_pending", "waiting_on": "appr-1", "what": "Waiting for approval", "wake_producer": "hitl_resolution_hook", "since": 1795250000.0, "due_at": null, "next_action": "resolve" }]
            }|}))
  in
  Alcotest.(check int) "waiting inventory rows" 1 (List.length wi.rows);
  let hdrs = Wire_runtime.mcp_headers ~method_:"tools/call" ~tool_name:"masc_status" () in
  Alcotest.(check (option string)) "MCP-Protocol-Version" (Some "2026-07-28")
    (List.assoc_opt "MCP-Protocol-Version" hdrs);
  Alcotest.(check (option string)) "Mcp-Method" (Some "tools/call")
    (List.assoc_opt "Mcp-Method" hdrs);
  Alcotest.(check (option string)) "Mcp-Name" (Some "masc_status")
    (List.assoc_opt "Mcp-Name" hdrs);
  Alcotest.(check (option string)) "X-Masc-Force-Json" (Some "true")
    (List.assoc_opt "X-Masc-Force-Json" hdrs);
  let mcp_tools =
    expect_ok "decode_mcp_tools_list"
      (Wire_runtime.decode_mcp_tools_list
         (parse_json
            {|{
              "jsonrpc": "2.0",
              "id": 1,
              "result": {
                "tools": [
                  {
                    "name": "masc_board_list",
                    "description": "List board posts",
                    "inputSchema": {
                      "type": "object",
                      "properties": { "limit": { "type": "integer" }, "hearth": { "type": "string" } },
                      "required": ["limit"]
                    }
                  }
                ]
              }
            }|}))
  in
  Alcotest.(check int) "1 mcp tool" 1 (List.length mcp_tools);
  Alcotest.(check (list string)) "required params" [ "limit" ]
    (List.hd mcp_tools).required_params;
  let mcp_res =
    expect_ok "decode_mcp_tools_call_result ok"
      (Wire_runtime.decode_mcp_tools_call_result ~tool_name:"masc_status"
         (parse_json
            {|{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"healthy"}],"isError":false}}|}))
  in
  Alcotest.(check bool) "mcp call ok" false mcp_res.is_error;
  Alcotest.(check (list string)) "mcp call text" [ "healthy" ] mcp_res.content_texts;
  let mcp_err =
    expect_ok "decode_mcp_tools_call_result jsonrpc error"
      (Wire_runtime.decode_mcp_tools_call_result ~tool_name:"masc_status"
         (parse_json
            {|{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"bad params"}}|}))
  in
  Alcotest.(check bool) "mcp call error flagged" true mcp_err.is_error

let test_wave4_layer3_wire_codecs () =
  (* 1. Skills snapshot preserves exact reference_json *)
  let sk_snap =
    expect_ok "decode_skills_snapshot preserves reference_json"
      (Wire_runtime.decode_skills_snapshot
         (parse_json
            {|{
              "schema": "masc.skill-snapshot/v1",
              "state": "ready",
              "snapshot": { "snapshot_revision": "snap-rev-1", "shadows": [], "rejections": [] },
              "surfaces": [
                {
                  "reference": {
                    "identity": { "source_id": "workspace", "package_id": "ocaml-coding", "name": "ocaml-coding" },
                    "content_revision": "sha256:abc"
                  },
                  "kind": "instruction",
                  "profile": { "summary": "OCaml rules" }
                }
              ]
            }|}))
  in
  Alcotest.(check int) "skills surface count" 1 (List.length sk_snap.surfaces);
  Alcotest.(check bool) "reference_json preserved" true
    (Option.is_some (List.hd sk_snap.surfaces).reference_json);
  (* 2. Skill editor sources, tools, loaded, preview, outcome, refresh *)
  let sources =
    expect_ok "decode_skill_editor_sources"
      (Wire_runtime.decode_skill_editor_sources
         (parse_json {|{"status":"ready","sources":[{"source_id":"workspace"},{"source_id":"local"}]}|}))
  in
  Alcotest.(check (list string)) "writable sources" [ "workspace"; "local" ] sources;
  let tools =
    expect_ok "decode_skill_editor_tools"
      (Wire_runtime.decode_skill_editor_tools
         (parse_json
            {|{"schema":"masc.skill-authoring-tools/v1","tools":[{"name":"masc_status","description":"Status","execution":"concurrent"}]}|}))
  in
  Alcotest.(check int) "authoring tools count" 1 (List.length tools);
  let loaded =
    expect_ok "decode_skill_editor_loaded"
      (Wire_runtime.decode_skill_editor_loaded
         (parse_json
            {|{
              "status": "ready",
              "reference": { "identity": { "source_id": "workspace", "package_id": "demo", "name": "demo" }, "content_revision": "rev-1" },
              "snapshot_revision": "snap-1",
              "source_text": "---\nname: demo\n---\nHello",
              "access": "read_write"
            }|}))
  in
  Alcotest.(check string) "loaded access" "read_write"
    (Wire_runtime.skill_access_to_string loaded.access);
  let prev =
    expect_ok "decode_skill_editor_preview"
      (Wire_runtime.decode_skill_editor_preview
         (parse_json
            {|{"ok":true,"status":"valid","preview":{"profile":{"kind":"instruction","activation_tool":"skill_demo","execution":"inline","context":{"body_bytes":42}},"diagnostics":["warn1"]}}|}))
  in
  Alcotest.(check (list string)) "preview diagnostics" [ "warn1" ] prev.diagnostics;
  let outcome =
    expect_ok "decode_skill_editor_outcome"
      (Wire_runtime.decode_skill_editor_outcome
         (parse_json
            {|{"status":"deleted_and_published","snapshot_revision":"snap-2","recovery_id":"rec-1","audit_status":"audit_call_returned"}|}))
  in
  Alcotest.(check string) "outcome status" "deleted_and_published" outcome.status;
  let refresh =
    expect_ok "decode_skill_refresh_receipt"
      (Wire_runtime.decode_skill_refresh_receipt
         (parse_json {|{"ok":true,"snapshot_revision":"snap-3","publication":"published"}|}))
  in
  Alcotest.(check string) "refresh publication" "published" refresh.publication;
  let del_body =
    Wire_runtime.encode_skill_delete_body ~reference_json:loaded.reference_json
      ~confirmed:true
  in
  Alcotest.(check bool) "delete body carries confirmed=true" true
    (match del_body with
    | `Assoc fs -> List.assoc_opt "confirmed" fs = Some (`Bool true)
    | _ -> false);
  (* 3. Async requests *)
  let async_snap =
    expect_ok "decode_async_requests"
      (Wire_runtime.decode_async_requests
         (parse_json
            {|{
              "schema": "masc.async-request-observation/v1",
              "status": "ready",
              "summary": { "active": 1, "runtime_owned": 1, "ownership_unknown": 0, "record_errors": 0 },
              "requests": [
                {
                  "request_id": "req-1",
                  "keeper_name": "alpha",
                  "submitted_by": "operator",
                  "status": "running",
                  "worker_ownership": "runtime_owned",
                  "submitted_at": 1795250000.0,
                  "elapsed_sec": 3.5
                }
              ],
              "record_errors": []
            }|}))
  in
  Alcotest.(check int) "async active" 1 async_snap.active;
  Alcotest.(check int) "async rows" 1 (List.length async_snap.requests);
  (* 4. Prompts *)
  let prompts =
    expect_ok "decode_prompts_catalog"
      (Wire_runtime.decode_prompts_catalog
         (parse_json
            {|{
              "prompts": [
                {
                  "key": "keeper.system",
                  "category": "keeper",
                  "operator_surface": "prompt_override",
                  "description": "Base prompt",
                  "effective": "Hello {{name}}",
                  "file_value": "Default",
                  "override_value": "Hello {{name}}",
                  "source": "override",
                  "has_override": true,
                  "override_default_moved": false,
                  "char_count": 14,
                  "template_variables": ["name"]
                }
              ],
              "held_back": []
            }|}))
  in
  Alcotest.(check int) "prompts count" 1 (List.length prompts.prompts);
  Alcotest.(check bool) "prompt has_override" true (List.hd prompts.prompts).has_override;
  let prompt_set_body =
    Wire_runtime.encode_prompt_set ~key:"keeper.system" ~value:"New text"
  in
  Alcotest.(check bool) "prompt set action" true
    (match prompt_set_body with
    | `Assoc fs -> List.assoc_opt "action" fs = Some (`String "set")
    | _ -> false);
  (* 5. Presets *)
  let presets =
    expect_ok "decode_presets_listing"
      (Wire_runtime.decode_presets_listing
         (parse_json
            {|{
              "ok": true,
              "presets": [
                {
                  "schema_version": 1,
                  "name": "baseline",
                  "description": "Stable",
                  "created_at": "2026-11-24T00:00:00Z",
                  "override_count": 2,
                  "override_keys": ["a", "b"],
                  "keepers": ["alpha"],
                  "assignment_count": 1,
                  "lane_count": 2
                }
              ],
              "unreadable": []
            }|}))
  in
  Alcotest.(check int) "presets count" 1 (List.length presets.presets);
  let pdet =
    expect_ok "decode_preset_detail"
      (Wire_runtime.decode_preset_detail
         (parse_json
            {|{
              "ok": true,
              "preset": {
                "name": "baseline",
                "description": "Stable",
                "created_at": "2026-11-24T00:00:00Z",
                "prompt_overrides": [{ "key": "a", "value": "x", "bytes": 1 }],
                "instructions": [{ "keeper_file": "alpha", "bytes": 10, "text": "Be concise" }],
                "assignments": [{ "keeper": "alpha", "runtime": "claude" }],
                "lanes": [{ "id": "verifier_exact", "available": true, "enabled": true, "slots": [], "cli_slots": [] }]
              },
              "directory": "/tmp/.masc/presets/baseline",
              "saved_settings": { "status": "matches" },
              "default_prompts": { "status": "matches", "changes": [] }
            }|}))
  in
  Alcotest.(check string) "preset detail saved_settings" "matches"
    pdet.saved_settings_status;
  let prep =
    expect_ok "decode_preset_restore_report"
      (Wire_runtime.decode_preset_restore_report
         (parse_json
            {|{
              "ok": true,
              "report": {
                "restored": "baseline",
                "autosave": "_autosave",
                "prompt_overrides": { "applied": ["a"], "skipped": [] },
                "instructions": { "applied": ["alpha"], "skipped": [] },
                "runtime": { "status": "committed" },
                "skipped_lanes": [],
                "skipped_assignments": []
              }
            }|}))
  in
  Alcotest.(check string) "preset restore runtime_status" "committed"
    prep.runtime_status;
  (* 6. Runtime params *)
  let params =
    expect_ok "decode_runtime_params"
      (Wire_runtime.decode_runtime_params
         (parse_json
            {|{
              "parameters": [
                {
                  "key": "keeper.max_turns",
                  "current": 16,
                  "default": 8,
                  "has_override": true,
                  "meta": { "description": "Max turns", "value_type": "int", "choices": [] }
                }
              ]
            }|}))
  in
  Alcotest.(check int) "runtime params count" 1 (List.length params.parameters);
  Alcotest.(check bool) "runtime param overridden" true
    (List.hd params.parameters).has_override

let test_wave4_layer4_wire_codecs () =
  let valid_sha = String.make 64 'a' in
  let set lane =
    match Wire_runtime.set_routing_action ~lane ~runtime_ids:["r1"; "r2"]
            ~expected_source_revision:(Some valid_sha) with
    | Ok action -> Wire_runtime.encode_runtime_routing_action action
    | Error detail -> Alcotest.fail detail
  in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "named route preserves ordered candidates and CAS" true
    (member "runtime_ids" (set "fast") = `List [`String "r1"; `String "r2"]
     && member "expected_source_revision" (set "fast") = `String valid_sha);
  Alcotest.(check bool) "media failover keeps its list contract" true
    (member "runtime_ids" (set "media_failover") = `List [`String "r1"; `String "r2"]
     && member "expected_source_revision" (set "media_failover") = `Null);
  (* 1. Runtime routing CRUD & CAS revision guard *)
  let j_set_ok =
    Wire_runtime.encode_runtime_routing_action
      (Wire_runtime.Route_set_named
         {
           lane = "fast";
           runtime_ids = [ "r1"; "r2" ];
           expected_source_revision = Some valid_sha;
         })
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "routing lane" "fast" (j_set_ok |> member "lane" |> to_string);
  Alcotest.(check string) "routing action" "set" (j_set_ok |> member "action" |> to_string);
  Alcotest.(check string) "routing CAS sha kept" valid_sha
    (j_set_ok |> member "expected_source_revision" |> to_string);
  let j_set_bad_sha =
    Wire_runtime.encode_runtime_routing_action
      (Wire_runtime.Route_set_named
         {
           lane = "fast";
           runtime_ids = [ "r1" ];
           expected_source_revision = Some "not-a-sha";
         })
  in
  Alcotest.(check bool) "invalid CAS sha omitted" true
    (j_set_bad_sha |> member "expected_source_revision" = `Null);
  let j_move =
    Wire_runtime.encode_runtime_routing_action
      (Wire_runtime.Route_exact_move
         { lane_id = "verifier"; runtime_id = "slot-2"; direction = `First })
  in
  Alcotest.(check string) "exact move lane prefix" "exact/verifier"
    (j_move |> member "lane" |> to_string);
  Alcotest.(check string) "exact move action" "move"
    (j_move |> member "action" |> to_string);
  Alcotest.(check string) "exact move direction" "first"
    (j_move |> member "direction" |> to_string);
  (* 2. Raw preview, lane inventory, standalone lanes, exact run detail, verifiers & quarantines *)
  let pv =
    expect_ok "decode_runtime_raw_preview"
      (Wire_runtime.decode_runtime_raw_preview
         (parse_json {|{"ok":true,"can_save":true,"runtime_validation":"ok"}|}))
  in
  Alcotest.(check bool) "raw preview ok && can_save" true (pv.ok && pv.can_save);
  let inv =
    expect_ok "decode_lane_inventory"
      (Wire_runtime.decode_lane_inventory
         (parse_json
            {|{"observed_at":1700000000.0,
               "package_read":{"directory":".masc/lanes","complete":true,"owner_present":true,"issues":[]},
               "rows":[{"id":"default","label":"Default","purpose":"chat",
                        "selection":{"kind":"failover"},"state":{"kind":"ready"}}]}|}))
  in
  Alcotest.(check int) "lanes inventory rows" 1 (List.length inv.rows);
  Alcotest.(check string) "lanes inventory dir" ".masc/lanes" inv.directory;
  let sl =
    expect_ok "decode_standalone_lanes"
      (Wire_runtime.decode_standalone_lanes
         (parse_json
            {|{"generated_at":"2026-11-24T00:00:00Z","observed_at_unix":1700000000.0,
               "lanes":[{"lane_id":"verifier","label":"Verifier","purpose":"verify","required":true,
                         "configuration_state":"configured","status":"ready",
                         "admitted_slots":["s1"],"cli_slots":[],"dropped_slots":[],"declared_slots":["s1"],
                         "retained_run_count":3,"running_count":0,"succeeded_count":2,"failed_count":1,"cancelled_count":0}]}|}))
  in
  Alcotest.(check int) "standalone lanes count" 1 (List.length sl.lanes);
  let rd =
    expect_ok "decode_exact_lane_run_detail"
      (Wire_runtime.decode_exact_lane_run_detail
         (parse_json
            {|{"run_id":"run-99","run_kind":"exact_output","lane":"verifier","status":"succeeded",
               "subject_id":"task-1","actor":"alpha","selected_slot":"s1","elapsed_s":1.25,
               "skill_evidence":{"state":"verified"},"input":{"q":"hi"},"output":{"ok":true}}|}))
  in
  Alcotest.(check string) "exact run detail run_id" "run-99" rd.run_id;
  Alcotest.(check (option string)) "exact run skill evidence" (Some "verified")
    rd.skill_evidence_state;
  let vr =
    expect_ok "decode_verification_runs"
      (Wire_runtime.decode_verification_runs
         (parse_json
            {|{"generated_at":"2026-11-24T00:00:00Z","count":1,
               "runs":[{"run_id":"vr-1","task_id":"t-1","status":"rejected","detail":"mismatch"}]}|}))
  in
  Alcotest.(check int) "verification runs count" 1 vr.count;
  Alcotest.(check (option string)) "verification run detail" (Some "mismatch")
    (List.hd vr.runs).detail;
  let q_snap =
    expect_ok "decode_board_attention_quarantines"
      (Wire_runtime.decode_board_attention_quarantines
         (parse_json
            {|{"count":1,"items":[{"keeper_name":"alpha","partition_id":"p1","candidate_id":"c1",
               "quarantine_id":"q1","phase":"quarantined","failure_category":"timeout","quarantined_at":1700000001.0}],"errors":[]}|}))
  in
  Alcotest.(check int) "quarantines count" 1 q_snap.count;
  let q_rec =
    Wire_runtime.encode_board_attention_quarantine_recovery ~candidate_id:"c1"
      ~expected_quarantine_id:"q1"
  in
  Alcotest.(check string) "quarantine recovery schema"
    "keeper.board_attention.quarantine.recovery.request.v1"
    (q_rec |> member "schema" |> to_string);
  (* 3. Lane Add-ons operator codecs *)
  let decl_create =
    Wire_runtime.encode_addon_declaration_save ~mode:`Create ~file_name:"demo.toml"
      ~source_text:"id = \"demo\"" ~expected_source_revision:(Some valid_sha)
  in
  Alcotest.(check bool) "addon decl create omits expected_source_revision" true
    (decl_create |> member "expected_source_revision" = `Null);
  let decl_save =
    Wire_runtime.encode_addon_declaration_save ~mode:`Save ~file_name:"demo.toml"
      ~source_text:"id = \"demo\"" ~expected_source_revision:(Some valid_sha)
  in
  Alcotest.(check string) "addon decl save includes valid sha" valid_sha
    (decl_save |> member "expected_source_revision" |> to_string);
  let act_body =
    Wire_runtime.encode_lane_addon_action ~instance_id:"inst-1"
      ~expected_incarnation:"inst-1" ~request_id:"tui-addon-1"
      ~action:(`Assoc [ ("op", `String "ping") ])
  in
  Alcotest.(check string) "addon act expected_incarnation" "inst-1"
    (act_body |> member "expected_incarnation" |> to_string);
  let asks =
    expect_ok "decode_lane_addon_asks"
      (Wire_runtime.decode_lane_addon_asks
         (parse_json
            {|{"asks":[{"declaration_id":"decl-1","title":"Demo","ask_id":"ask-1","asked_at":1700000002.0,
               "questions":[{"question_id":"q-1","header":"Approval","prompt":"Confirm?","mode":"single"}],"resolution":{"state":"open"}}]}|}))
  in
  Alcotest.(check int) "addon asks count" 1 (List.length asks);
  Alcotest.(check bool) "addon ask resolution state" true
    (match (List.hd asks).resolution with Wire_work.Ask_open -> true | _ -> false);
  let answers = parse_json
      {|[{"question_id":"q-1","response":{"kind":"chose","choice_ids":["yes"]}},
          {"question_id":"q-2","response":{"kind":"wrote","text":"note"}},
          {"question_id":"q-3","response":{"kind":"skipped"}}]|} in
  let decoded = expect_ok "decode structured slash answers" (Wire_work.decode_ask_answers answers) in
  let answer_request = Wire_runtime.encode_lane_addon_ask_answer
      ~declaration_id:"decl-1" ~ask_id:"ask-1" ~answers:decoded () in
  Alcotest.(check string) "slash and modal use the same answer shape"
    (Yojson.Safe.to_string answers) (Yojson.Safe.to_string (member "answers" answer_request));
  Alcotest.(check bool) "answers reject unknown response kinds" true
    (Result.is_error (Wire_work.decode_ask_answers
        (parse_json {|[{"question_id":"q-1","response":{"kind":"choose"}}]|})));
  (* 4. Browser operator codecs *)
  let sc_req =
    Wire_runtime.encode_browser_scene_request ~client_id:"cl-1" ~tab_id:7
      ~view:`Regions
  in
  Alcotest.(check string) "browser scene lane" "live"
    (sc_req |> member "lane" |> to_string);
  Alcotest.(check int) "browser scene tabId" 7
    (sc_req |> member "tabId" |> to_int);
  let sc =
    expect_ok "decode_browser_scene_response"
      (Wire_runtime.decode_browser_scene_response
         (parse_json
            {|{"documentId":"doc-1","tabId":7,"url":"https://example.com","title":"Ex",
               "viewport":{"width":1280,"height":720,"scrollX":0,"scrollY":0},
               "view":"regions","truncated":false,
               "nodes":[{"nodeId":"n1","kind":"button","tag":"button","text":"Go","clickable":true,"editable":false}]}|}))
  in
  Alcotest.(check int) "browser scene nodes" 1 (List.length sc.nodes);
  Alcotest.(check (float 0.01)) "browser scene viewport width" 1280.0 sc.width;
  let sh =
    expect_ok "decode_browser_screenshot_response"
      (Wire_runtime.decode_browser_screenshot_response
         (parse_json
            {|{"ok":true,"data":{"tabId":7,"url":"https://example.com","title":"Ex","mimeType":"image/png","data":"AAAA"}}|}))
  in
  Alcotest.(check int) "browser screenshot base64 len" 4 sh.base64_bytes;
  let op =
    expect_ok "decode_browser_op_receipt"
      (Wire_runtime.decode_browser_op_receipt
         (parse_json {|{"ok":true,"action":"click","status":"done"}|}))
  in
  Alcotest.(check bool) "browser op receipt ok" true op.ok;
  let op_inner_err =
    expect_ok "decode_browser_op_receipt inner isError"
      (Wire_runtime.decode_browser_op_receipt
         (parse_json
            {|{"ok":true,"data":{"isError":true,"content":[{"type":"text","text":"tab closed"}]}}|}))
  in
  Alcotest.(check bool) "browser op inner isError marks ok=false" false
    op_inner_err.ok;
  Alcotest.(check (option string)) "browser op inner error text" (Some "tab closed")
    op_inner_err.error

let test_keeper_lifecycle_wire_codecs () =
  (* Path encoding including special characters *)
  Alcotest.(check string) "boot path plain"
    "/api/v1/keepers/alpha-1/boot"
    (Wire_fleet.keeper_lifecycle_path ~keeper:"alpha-1" Wire_fleet.Keeper_boot);
  Alcotest.(check string) "boot path percent-encodes special chars"
    "/api/v1/keepers/ops%20team%2F1%25/boot"
    (Wire_fleet.keeper_lifecycle_path ~keeper:"ops team/1%"
       Wire_fleet.Keeper_boot);
  Alcotest.(check string) "shutdown path percent-encodes special chars"
    "/api/v1/keepers/ops%20team%2F1/shutdown"
    (Wire_fleet.keeper_lifecycle_path ~keeper:"ops team/1"
       Wire_fleet.Keeper_shutdown);
  Alcotest.(check string) "directive path percent-encodes special chars"
    "/api/v1/keepers/ops%20team%2F1/directive"
    (Wire_fleet.keeper_lifecycle_path ~keeper:"ops team/1"
       Wire_fleet.Keeper_wakeup);
  (* Directive body encoding with & without expected_workspace *)
  let ws = ("/tmp/ws", "/tmp/ws/.masc") in
  let wake_no_ws =
    Wire_fleet.encode_keeper_lifecycle_body Wire_fleet.Keeper_wakeup
  in
  Alcotest.(check string) "wakeup without ws"
    {|{"action":"wakeup"}|} (Yojson.Safe.to_string wake_no_ws);
  let pause_ws =
    Wire_fleet.encode_keeper_lifecycle_body ~expected_workspace:ws
      Wire_fleet.Keeper_pause
  in
  Alcotest.(check string) "pause action" "pause"
    (match Yojson.Safe.Util.member "action" pause_ws with
    | `String s -> s
    | _ -> "");
  Alcotest.(check bool) "pause carries expected_workspace" true
    (match Yojson.Safe.Util.member "expected_workspace" pause_ws with
    | `Assoc _ -> true
    | _ -> false);
  let resume_ws =
    Wire_fleet.encode_keeper_lifecycle_body ~expected_workspace:ws
      (Wire_fleet.Keeper_resume { operator_operation_id = "op-123" })
  in
  Alcotest.(check string) "resume action" "resume"
    (match Yojson.Safe.Util.member "action" resume_ws with
    | `String s -> s
    | _ -> "");
  Alcotest.(check string) "resume operator_operation_id" "op-123"
    (match Yojson.Safe.Util.member "operator_operation_id" resume_ws with
    | `String s -> s
    | _ -> "");
  (* Lifecycle reply decoding: 200 ok, already_live, already_absent, 202 partial, ok=false error, invalid *)
  let r_live =
    expect_ok "decode already_live"
      (Wire_fleet.decode_keeper_lifecycle_reply
         (parse_json
            {|{"ok":true,"action":"boot","name":"alpha","already_live":true}|}))
  in
  Alcotest.(check bool) "already_live ok" true r_live.ok;
  Alcotest.(check bool) "already_live true" true r_live.already_live;
  Alcotest.(check bool) "already_absent false" false r_live.already_absent;
  let r_absent =
    expect_ok "decode already_absent"
      (Wire_fleet.decode_keeper_lifecycle_reply
         (parse_json
            {|{"ok":true,"action":"shutdown","name":"alpha","already_absent":true}|}))
  in
  Alcotest.(check bool) "already_absent true" true r_absent.already_absent;
  let r_202 =
    expect_ok "decode 202 partial resume"
      (Wire_fleet.decode_keeper_lifecycle_reply
         (parse_json
            {|{"ok":false,"action":"resume","operation":"resume_owner","name":"alpha","committed":true,"error":"projection timeout"}|}))
  in
  Alcotest.(check bool) "202 ok=false" false r_202.ok;
  Alcotest.(check bool) "202 committed=true" true r_202.committed;
  Alcotest.(check (option string)) "202 error preserved"
    (Some "projection timeout") r_202.error;
  let r_err =
    expect_ok "decode ok=false error"
      (Wire_fleet.decode_keeper_lifecycle_reply
         (parse_json {|{"ok":false,"error":"keeper is operator-paused"}|}))
  in
  Alcotest.(check bool) "err ok=false" false r_err.ok;
  Alcotest.(check bool) "err committed=false" false r_err.committed;
  Alcotest.(check (option string)) "err reason"
    (Some "keeper is operator-paused") r_err.error;
  Alcotest.(check bool) "rejects payload without ok" true
    (Result.is_error
       (Wire_fleet.decode_keeper_lifecycle_reply
          (parse_json {|{"action":"boot","name":"alpha"}|})));
  (* HTTP 202 Accepted is classified as Ok body (never dropped as HTTP error) *)
  let ep = Http_client.make_endpoint ~host:"127.0.0.1" ~port:8935 () in
  let body_202 =
    {|{"ok":false,"action":"resume","name":"alpha","committed":true,"error":"lane offline"}|}
  in
  match Http_client.classify_response ep ~status:202 ~body:body_202 with
  | Ok raw -> Alcotest.(check string) "202 body preserved verbatim" body_202 raw
  | Error err ->
      Alcotest.failf "expected HTTP 202 to succeed, got %s"
        (Http_client.http_error_to_string err)

let () =
  Alcotest.run "masc_tui_v2_protocol_net"
    [
      ( "protocol"
      , [
          Alcotest.test_case "wire_common" `Quick test_wire_common;
          Alcotest.test_case "wire_fleet" `Quick test_wire_fleet;
          Alcotest.test_case "queued operation pages" `Quick test_chat_queue_pages;
          Alcotest.test_case "agui_chat_stream_and_history_provenance" `Quick
            test_agui_chat_stream_and_history_provenance;
          Alcotest.test_case "chat_history_speaker" `Quick
            test_chat_history_speaker;
          Alcotest.test_case "wire_chat_journal refusals" `Quick
            test_wire_chat_journal_refusals;
          Alcotest.test_case "wire_work" `Quick test_wire_work;
          Alcotest.test_case "wire_knowledge" `Quick test_wire_knowledge;
          Alcotest.test_case "wire_runtime" `Quick test_wire_runtime;
          Alcotest.test_case "account cost state: credit and quota windows" `Quick
            test_account_cost_state_credit_and_quota;
          Alcotest.test_case "wire_infra" `Quick test_wire_infra;
          Alcotest.test_case "wire_config" `Quick test_wire_config;
          Alcotest.test_case "wire_observer" `Quick test_wire_observer;
          Alcotest.test_case "wire_observer agent_core payload shapes" `Quick
            test_wire_observer_agent_core_payload_shapes;
          Alcotest.test_case "live_round1_board_and_planning" `Quick
            test_live_round1_wire_payloads;
          Alcotest.test_case "round2_wire_regressions_P1_1_3_4" `Quick
            test_round2_wire_regressions;
          Alcotest.test_case "round3_wire_config_unset_sentinels" `Quick
            test_round3_wire_config_unset_sentinels;
          Alcotest.test_case "v25_data_pipeline_decoders" `Quick
            test_v25_data_pipeline_decoders;
          Alcotest.test_case "efficiency_null_cache_hit_pct_and_window_kind" `Quick
            test_efficiency_null_cache_hit_pct_preserved;
          Alcotest.test_case "P1-7 wire_fleet offline vs failing SSOT" `Quick
            test_p1_7_wire_fleet_offline_vs_failing_ssot;
          Alcotest.test_case "Memory OS internals, effort labels, capability keys & setup codecs" `Quick
            test_tui_memory_os_and_runtime_setup_codecs;
          Alcotest.test_case "Keeper memory facts, activity (8 kinds) & v19 health fleet codecs" `Quick
            test_keeper_memory_facts_activity_and_health_decoders;
          Alcotest.test_case "Feature Wave 1: Artifacts, Browser clients/tabs, Lane Addons & observer routing" `Quick
            test_feature_wave1_wire_decoders;
          Alcotest.test_case "Feature Wave 2: Keeper Context (8 routes), Live Tools P0, Skills, Hearths & Artifact Checks" `Quick
            test_wave2_live_wire_codecs;
          Alcotest.test_case "Feature Wave 3: Fusion, Harness, Verification Evidence, Code/Git, Memory, Keeper Logs & Identity, Addons Catalog, Connector Names" `Quick
            test_wave3_live_wire_codecs;
          Alcotest.test_case "Feature Wave 4 Layer 1: Turn Flow, Memory OS snapshot, Checkpoints, Operator Note & AG-UI Retry/Progress" `Quick
            test_wave4_layer1_wire_codecs;
          Alcotest.test_case "Feature Wave 4 Layer 2: HITL Gate Policy/Rules/Modes/Retry/Recovery, Tool Quality, Waiting Inventory & Stateless MCP 2026-07-28" `Quick
            test_wave4_layer2_wire_codecs;
          Alcotest.test_case "Feature Wave 4 Layer 3: Skills Editor/CRUD, Async Requests, Prompts, Presets & Runtime Params" `Quick
            test_wave4_layer3_wire_codecs;
          Alcotest.test_case "Feature Wave 4 Layer 4: Runtime Lanes CRUD, Exact Run Detail, Verifiers, Quarantines, Add-ons & Browser Operator" `Quick
            test_wave4_layer4_wire_codecs;
          Alcotest.test_case "Keeper lifecycle wire codecs (paths, directives, 202 partial, replies)" `Quick
            test_keeper_lifecycle_wire_codecs;
        ] );
      ( "net"
      , [
          Alcotest.test_case "ui_bus_coalesce_and_512_gap" `Quick test_ui_bus;
          Alcotest.test_case "ui_bus retains final receipts through overflow" `Quick
            test_ui_bus_preserves_ordered_receipts;
          Alcotest.test_case "ui_bus_concurrent_no_lost_wakeup" `Quick
            test_ui_bus_concurrent_no_lost_wakeup;
          Alcotest.test_case "sse_hub_diff_and_http_409" `Quick
            test_sse_hub_and_http_client;
          Alcotest.test_case "timeout_diagnostics_and_sanitization" `Quick
            test_timeout_diagnostics_and_sanitization;
          Alcotest.test_case "io_domain_isolation_and_shutdown" `Quick
            test_io_domain_isolation_and_shutdown;
          Alcotest.test_case "worker_pool_and_voice_runner" `Quick
            test_worker_and_voice_runner;
        ] );
    ]
