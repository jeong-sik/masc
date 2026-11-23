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
  let keepers = expect_ok "roster" (Wire_fleet.decode_keepers_roster ~observed_at:t0 roster_json) in
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
            {
              control_token = "ctrl-42";
              target = Wire_fleet.Interrupt_turn_token "turn-tok-9";
            };
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
  (* Wiki page detail with nullable outgoing_links[].exists *)
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
  Alcotest.(check (option bool)) "external link exists=None" None (List.hd wp.outgoing_links).exists;
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
  let kdiff =
    expect_ok "keeper memory diff"
      (Wire_knowledge.decode_memory_diff
         (parse_json
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
            }|}))
  in
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
              "counts": { "total_claims_now": 3, "added": 1, "updated": 0, "retracted": 0, "incomplete_batches": 0, "aborted_batches": 0 },
              "retrieval_heat": { "hot": 1, "warm": 0, "cold": 0, "never_retrieved": 2, "total_events": 1, "unreadable_event_lines": 0 },
              "unparseable_timestamps": 0,
              "revisions": [{ "rev": 5, "batch_id": "b1", "fact_id": "f1", "recorded_at": "2026-11-21T18:00:00Z", "op": "added" }],
              "added": [{ "seq": 5, "batch_id": "b1", "fact_id": "f1", "summary": "New claim", "recorded_at": "2026-11-21T18:00:00Z", "payload": {} }],
              "updated": [],
              "retracted": []
            }|}))
  in
  (match wdiff.body with
  | Wire_knowledge.World_diff { counts = { total_claims_now = 3; _ }; _ } -> ()
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
  Alcotest.(check bool) "ssh_active_sessions null -> Absent" true
    (Observed.equal Int.equal sb.ssh_active_sessions Observed.absent);
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
  Alcotest.(check bool) "tts_available" true caps.tts_available;
  Alcotest.(check bool) "stt_available" false caps.stt_available;
  (* POST /api/v1/voice/probe/tts sends key "message", NOT "text" *)
  let tts_body = Voice_runner.encode_tts_probe_request ~text:"hello world" in
  Alcotest.(check (list string)) "tts probe exact keys" [ "message" ] (assoc_keys tts_body);
  Alcotest.(check string) "tts probe message" "hello world"
    (expect_ok "message" (Wire_common.required_nonblank_string tts_body "message"));
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
              tts_available = true;
            });
      record_until_stopped =
        (fun ~device:_ ~stop_signal ~on_level ->
          let n = Atomic.fetch_and_add session_counter 1 + 1 in
          on_level (-18.0);
          Eio.Promise.await stop_signal;
          if n = 1 then Eio.Promise.await first_gate;
          Ok (Printf.sprintf "ptt_%d.wav" n));
      transcribe = (fun ~audio_path -> Ok ("heard:" ^ audio_path));
      speak = (fun ~text:_ ~voice_id:_ -> Ok ());
      cleanup_audio = (fun ~audio_path -> cleaned_paths := audio_path :: !cleaned_paths);
    }
  in
  let runner =
    Voice_runner.create ~sw ~backend ~on_event:(function
      | Voice_runner.Transcript_ready text ->
          ignore (Eio.Promise.try_resolve resolve_transcript text : bool)
      | Voice_runner.Phase_changed _ | Voice_runner.Level_meter _
      | Voice_runner.Speak_done | Voice_runner.Capabilities _
      | Voice_runner.Voice_error _ ->
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
  | Voice_runner.Voice_speaking | Voice_runner.Voice_failed _ ->
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

  (* R2-P1-3: /api/v1/dashboard/gate live key "approval_queue" (array, empty, null)
     alongside legacy "pending". *)
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
         (parse_json {|{ "approval_queue": [] }|}))
  in
  Alcotest.(check int) "0 live gates" 0 (List.length empty_gates);
  let null_gates =
    expect_ok "live gate null approval_queue"
      (Wire_work.decode_gate_pending_list
         (parse_json {|{ "approval_queue": null }|}))
  in
  Alcotest.(check int) "null approval_queue -> empty list" 0
    (List.length null_gates);
  let legacy_gates =
    expect_ok "legacy gate pending"
      (Wire_work.decode_gate_pending_list
         (parse_json
            {|{ "pending": [{ "id": "leg-1", "keeper_name": "alpha", "tool_name": "bash", "phase": "queued" }] }|}))
  in
  Alcotest.(check int) "legacy pending still decodes" 1
    (List.length legacy_gates);

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
    (Wire_runtime.models_metrics_path ~window_minutes:1440 ~bucket_minutes:60 ());
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
              "slots": [
                [1795253600, 3, 0, 1],
                [1795250000, 1, 0, 0]
              ]
            }
          }
        ],
        "candle": { "issued_milli": "10000", "burned_milli": "2000", "circulating_milli": "8000" }
      }|}
  in
  let ks =
    expect_ok "live keeper decode"
      (Wire_fleet.decode_keepers_roster ~observed_at:t0 live_keeper_json)
  in
  let k0 = List.hd ks in
  Alcotest.(check (option int)) "turn_count fallback from runtime_lane_observation"
    (Some 77) (Observed.to_option k0.total_turns);
  Alcotest.(check (list (float 0.01))) "recent_turns.slots sorted ascending (ok+fail)"
    [ 1.0; 4.0 ] k0.activity_sparkline_24h;
  let extras =
    expect_ok "decode_keepers_roster_extras"
      (Wire_fleet.decode_keepers_roster_extras live_keeper_json)
  in
  Alcotest.(check bool) "sandbox_profile = microvm" true
    (List.assoc_opt "alpha-builder" extras.sandbox_profiles
     = Some Wire_fleet.Profile_microvm);
  Alcotest.(check (option string)) "candle circulating fallback" (Some "8000")
    (Option.map (fun (c : Wire_fleet.candle_summary_fallback) -> c.circulating_milli)
       extras.candle_summary);
  let enrichments, _ =
    expect_ok "decode_execution_keeper_enrichments"
      (Wire_fleet.decode_execution_keeper_enrichments
         (parse_json
            {|{ "keepers": [{ "name": "alpha-builder", "context_ratio": 0.42, "sandbox_profile": "remote_ssh" }] }|}))
  in
  Alcotest.(check (option (float 0.01))) "execution enrichment context_ratio"
    (Some 0.42) (List.hd enrichments).context_ratio;
  let companies =
    Wire_fleet.group_by_company ~sandbox_profiles:extras.sandbox_profiles
      ~keeper_costs_24h:[ ("alpha-builder", 0.35) ]
      ks
  in
  let cg = List.hd companies in
  Alcotest.(check string) "company = Platform Core" "Platform Core" cg.company;
  Alcotest.(check int) "company microvm_count = 1" 1 cg.microvm_count;
  Alcotest.(check int) "company turns_24h = 5" 5 cg.turns_24h;
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
      context_ratio = Observed.unreported;
      total_turns = Observed.unreported;
      total_tokens = Observed.unreported;
      cost_24h_usd = Observed.unreported;
      last_turn_at_unix = None;
      active_turn = None;
      activity_sparkline_24h = [];
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
          "verified_facts_count": 5, "decisions_count": 3, "open_threads_count": 1
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
        state = Wire_fleet.Accepted_running;
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
        state = Wire_fleet.Accepted_queued;
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
  | Wire_fleet.Chunk_text_delta { operation_id = Some "tui-99-1"; delta = "안녕하세요" }
    ->
      ()
  | _ -> Alcotest.fail "expected Chunk_text_delta");
  let text_delta_no_run =
    expect_ok "TEXT_MESSAGE_CONTENT without runId or operation_id"
      (Wire_fleet.decode_chat_stream_chunk
         (parse_json
            {|{"type":"TEXT_MESSAGE_CONTENT","threadId":"t","timestamp":1.0,"delta":"!"}|}))
  in
  (match text_delta_no_run with
  | Wire_fleet.Chunk_text_delta { operation_id = None; delta = "!" } -> ()
  | _ -> Alcotest.fail "expected Chunk_text_delta with None operation_id");
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
  | Wire_fleet.Chunk_thinking_delta { operation_id = Some "tui-99-1"; delta = "checking logs" }
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
    expect_ok "TOOL_CALL_END without tool_name/ok preserves ok=None"
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
  | Wire_fleet.Chunk_tool_end
      { tool_use_id = "scope-2-block-1"; tool_name = None; ok = None; _ } ->
      ()
  | _ -> Alcotest.fail "expected Chunk_tool_end with ok=None");
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
  (match native_start with
  | Wire_fleet.Chunk_tool_start { tool_use_id = "nt-1"; tool_name = "Bash"; _ } ->
      ()
  | _ -> Alcotest.fail "expected Chunk_tool_start from KEEPER_NATIVE_TOOL_START");
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
      { tool_use_id = "nt-1"; tool_name = Some "Bash"; ok = Some false; _ } ->
      ()
  | _ -> Alcotest.fail "expected Chunk_tool_end with ok=Some false");
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
  Alcotest.(check (option string)) "user operation_id" (Some "tui-99-1") u_msg.operation_id;
  Alcotest.(check (option string)) "user transcript_slot" (Some "accepted_user") u_msg.transcript_slot;
  Alcotest.(check bool) "failure role is Role_request_failure" true
    (f_msg.role = Wire_fleet.Role_request_failure);
  Alcotest.(check (option string)) "failure operation_id" (Some "tui-99-1") f_msg.operation_id;
  Alcotest.(check (option string)) "failure transcript_slot" (Some "settled_failure") f_msg.transcript_slot;
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
            {"identity":"e6","recorded_at":1795252006.0,"revision":6,"kind":"removed","before":[{"memory_id":"f4","claim":null}],"after":[],"reason":null},
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
    (expect_err "reject duplicate activity identities"
       (Wire_knowledge.decode_keeper_memory_activity
          (parse_json
             {|{"keeper":"alpha","undecodable_lines":0,"activity":{"limit":10,"journal_lines":2,"notes":[],"events":[{"identity":"dup","recorded_at":1.0,"revision":1,"kind":"created","before":[],"after":[{"memory_id":"f1","claim":"c1"}],"reason":null},{"identity":"dup","recorded_at":2.0,"revision":2,"kind":"created","before":[],"after":[{"memory_id":"f2","claim":"c2"}],"reason":null}]}}|}))
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
               "snapshot_bytes": 0,
               "added": 0,
               "removed": 0,
               "snapshot_present": false,
               "age_bins": null,
               "facts_by_hour": [],
               "librarian_failures": 0,
               "read_error": null,
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
    (expect_err "reject 23-element age_bins"
       (Wire_knowledge.decode_keeper_memory_health_fleet
          (parse_json
             {|{"schema":"keeper.memory_os.current_health.v19","generated_at":1.0,"keepers":[{"keeper_id":"a","revision":1,"updated_at":1.0,"facts":1,"observed_facts":1,"derived_facts":0,"snapshot_bytes":10,"added":0,"removed":0,"snapshot_present":true,"age_bins":[0,0,0],"facts_by_hour":[],"librarian_failures":0,"read_error":null,"alerts":[]}]}|}))
      : string)

let () =
  Alcotest.run "masc_tui_v2_protocol_net"
    [
      ( "protocol"
      , [
          Alcotest.test_case "wire_common" `Quick test_wire_common;
          Alcotest.test_case "wire_fleet" `Quick test_wire_fleet;
          Alcotest.test_case "agui_chat_stream_and_history_provenance" `Quick
            test_agui_chat_stream_and_history_provenance;
          Alcotest.test_case "wire_work" `Quick test_wire_work;
          Alcotest.test_case "wire_knowledge" `Quick test_wire_knowledge;
          Alcotest.test_case "wire_runtime" `Quick test_wire_runtime;
          Alcotest.test_case "wire_infra" `Quick test_wire_infra;
          Alcotest.test_case "wire_config" `Quick test_wire_config;
          Alcotest.test_case "wire_observer" `Quick test_wire_observer;
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
        ] );
      ( "net"
      , [
          Alcotest.test_case "ui_bus_coalesce_and_512_gap" `Quick test_ui_bus;
          Alcotest.test_case "sse_hub_diff_and_http_409" `Quick
            test_sse_hub_and_http_client;
          Alcotest.test_case "io_domain_isolation_and_shutdown" `Quick
            test_io_domain_isolation_and_shutdown;
          Alcotest.test_case "worker_pool_and_voice_runner" `Quick
            test_worker_and_voice_runner;
        ] );
    ]
