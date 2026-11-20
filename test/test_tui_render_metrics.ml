open Alcotest
module Types = Masc_tui_types
module Decode = Masc.Tui_decode
module Layout = Masc_tui_message_layout
module Render_metrics = Masc_tui_render_metrics
module Render_prim = Masc_tui_render_prim

(* The assertions read English; the TUI opens in Korean. *)
let make_state () =
  let state = Types.create_state ~workspace:"" ~port:0 () in
  state.Types.ui_language <- Types.Lang_en;
  state
;;

let test_compact_connection_priority () =
  let module P = Types.Http_refresh_progress in
  let state = make_state () in
  state.connection_status <- Types.Connected;
  state.workspace_identity <- Types.Workspace_identity_match;
  let expect description expected =
    check bool description true (Render_prim.compact_connection_state state = expected) in
  let make_progress outcome =
    P.start ~started_ns:1L
    |> fun progress -> P.observe progress (Started (Keepers, 1L))
    |> fun progress -> P.observe progress (Completed (Keepers, 2L, outcome))
    |> P.finish ~finished_ns:3L in
  let set progress = state.http_refresh_progress <- Some (state.workspace_authority, progress) in
  expect "a connected HTTP observation remains distinct" (Compact_http Connected);
  set (P.start ~started_ns:1L);
  expect "an active read is not summarized as settled" Compact_reading;
  set (make_progress Failed);
  expect "a failed read takes priority over HTTP connectivity" Compact_read_failed;
  set (make_progress (Composed (Runtime_parts { catalogue=Part_received; usage=Part_failed })));
  expect "a partial read remains distinct from complete failure" Compact_read_partial;
  state.connection_status <- Disconnected;
  expect "HTTP failure is not weakened by a partial read" (Compact_http Disconnected);
  state.connection_status <- Connected;
  set (make_progress Interrupted);
  expect "an interrupted read is not reported as complete" Compact_read_interrupted;
  let pending_failure = P.start ~started_ns:1L
    |> fun progress -> P.observe progress (Started (Surface_data Runtime_quota, 1L))
    |> fun progress -> P.observe progress (Component_started (Provider_windows, 1L))
    |> fun progress -> P.observe progress (Component_completed (Provider_windows, 2L,
         Component_returned Part_failed)) in
  set pending_failure;
  expect "a failed component is noticed before the parent settles" Compact_read_failed;
  state.workspace_identity <- Workspace_identity_match_unconfirmed "unread";
  expect "unconfirmed workspace takes priority" Compact_workspace_unconfirmed;
  state.workspace_identity <- Workspace_identity_unread;
  state.connection_status <- Degraded;
  expect "a partial HTTP read does not hide an unread workspace" Compact_workspace_unread;
  state.connection_status <- Disconnected;
  state.http_refresh_progress <- None;
  expect "before any workspace read, a failed HTTP refresh remains visible"
    (Compact_http Disconnected);
  state.connection_status <- Connected;
  state.workspace_identity <- Workspace_identity_mismatch
      { local_base_path="/local"; server_base_path="/other" };
  expect "a workspace mismatch takes priority" Compact_workspace_mismatch;
  state.workspace_identity <- Workspace_identity_match;
  state.http_refresh_progress <- Some (Workspace_authority 99, make_progress Failed);
  expect "another workspace's failure is not promoted" (Compact_http Connected)
;;

let test_metrics_scroll_tracks_card_reflow () =
  let rebase scroll previous_cards current_cards =
    Render_metrics.rebase_scroll_for_cards ~scroll ~previous_cards ~current_cards in
  check int "a reading keeps its place when cards join the scroll" 17 (rebase 12 (Some 0) 5);
  check int "a reading keeps its place when cards become fixed" 12 (rebase 17 (Some 5) 0);
  check int "the beginning remains the beginning" 0 (rebase 0 (Some 0) 5);
  check int "input before the first frame belongs to the new list" 1 (rebase 1 None 5);
  check int "End remains a sentinel until the frame clamps it"
    Types.clamped_scroll_end (rebase Types.clamped_scroll_end (Some 0) 5);
  let state = make_state () in
  Types.apply_clamped_scroll state
    (Metrics_scroll { scroll = 17; content_height = 4; card_rows = Some 5 });
  check int "the reported scroll is retained" 17 state.metrics_scroll;
  check int "the reported content height is retained" 4 state.metrics_content_height;
  check (option int) "the card prefix is retained for the next frame"
    (Some 5) state.metrics_scroll_card_rows;
  Types.reset_metrics_scroll state;
  check int "a new list has no stale page height" 0 state.metrics_content_height;
  check (option int) "a new list has no previous card prefix" None state.metrics_scroll_card_rows
;;

let make_keeper ?(paused = false) name : Decode.keeper =
  { k_origin = Masc.Tui_decode.Persisted_keeper
  ; k_name = name
  ; k_paused = paused
  ; k_identity = Ok { k_trace_id = "trace-" ^ name; k_created_at = "2026-09-01T00:00:00Z"; k_updated_at = "2026-09-05T12:00:00Z" }
  ; k_activity = Some { k_current_task_id = None; k_total_turns = 10; k_total_tokens = 5000; k_total_cost_usd = Result.get_ok (Keeper_cost_coverage.observe Keeper_cost_coverage.empty (Keeper_cost_coverage.Priced 0.05)); k_last_turn_at = Some 1788609600.; k_last_proactive_outcome = None }
  }
;;

let make_keeper_health ~keeper_id ~facts ~snapshot_bytes : Masc.Tui_decode_memory_health.memory_keeper_health =
  { (Memory_keeper_health_fixture.keeper_without_source ~keeper_id ~facts ~snapshot_bytes) with
    mkh_observed_facts = facts - 2
  }
;;

let make_memory_health ~total_facts ~source_facts ~keepers : Masc.Tui_decode_memory_health.memory_health_snapshot =
  { mhs_generated_at = 1000.0
  ; mhs_keepers = keepers
  ; mhs_refused_keepers = []
  ; mhs_total_facts = total_facts
  ; mhs_total_observed_facts = total_facts - source_facts
  ; mhs_total_derived_facts = 0
  ; mhs_total_support_invalidations = 0
  ; mhs_total_snapshot_bytes = 4096
  ; mhs_total_source_facts = source_facts
  ; mhs_total_source_invalidations = 0
  ; mhs_total_source_snapshot_bytes = 1024
  ; mhs_total_librarian_failures = 0
  ; mhs_total_librarian_unread_turns = Some 0
  ; mhs_total_librarian_continuity_unread_atoms = 0
  ; mhs_total_librarian_continuity_unmeasured = 0
  ; mhs_total_vision_ingest_errors = 0
  ; mhs_total_read_errors = 0
  ; mhs_total_source_read_errors = 0
  ; mhs_warn_alerts = 0
  ; mhs_error_alerts = 0
  ; mhs_starving_keepers = 0
  ; mhs_librarian_attention_required_keepers = 0
  }
;;

let make_gate_pending ~id ~keeper : Decode.gate_pending =
  { gp_id = id
  ; gp_keeper = keeper
  ; gp_operation = "tool_execute"
  ; gp_display_tool = "bash"
  ; gp_input_preview = Some "echo test"
  ; gp_input_rows = Decode.Flattened None
  ; gp_execution_cwd = None
  ; gp_execution_sandbox = None
  ; gp_waiting_s = Some 10.0
  ; gp_phase = Decode.Gate_queued
  ; gp_judge_advice = None
  ; gp_auto_judge_detail = None
  ; gp_retry_request = None
  }
;;

let contains text needle =
  try ignore (Str.search_forward (Str.regexp_string needle) text 0); true
  with Not_found -> false

let contains_plain text needle =
  contains (Masc_tui_theme.strip_sgr text) needle

let domain_task ~id ~created_at ~status : Masc_domain.task =
  { id; title = id; description = ""; task_status = status; priority = 3;
    files = []; created_at; created_by = Some "producer";
    predecessor_task_id = None; contract = None;
    execution_links = Masc_domain.no_execution_links; handoff_context = None;
    cycle_count = 0; skills = [] }

let test_calculate_kpis_empty () =
  let state = make_state () in
  let kpis = Render_metrics.calculate_kpis state in
  check bool "unobserved tasks stay unknown" true (Option.is_none kpis.tasks);
  check bool "unobserved turns stay unknown" true (Option.is_none kpis.turns);
  let output = String.concat "\n" (Render_metrics.render_section_fleet ~cols:160 state) in
  (* Under "Engine memory" and "Scheduler lag", which the section draws above
     each block, so the state is named and the subject is not said twice. *)
  check bool "missing GC is visible" true
    (contains output "Engine memory");
  check bool "missing scheduler is visible" true
    (contains output "Scheduler lag");
  check bool "no fabricated heap" false (contains output "42.5");
  check bool "no fabricated latency" false (contains output "0.82")
;;

let identity_without_blocks () =
  { Decode.sid_version = "0.0.0"
  ; sid_binary_commit = "deadbeef"
  ; sid_binary_commit_age_s = None; sid_runtime_instance_id = None
  ; sid_base_path = Masc.Tui_decode.Canonical_path.of_path "/tmp"
  ; sid_masc_root = Masc.Tui_decode.Canonical_path.of_path "/tmp"
  ; sid_executable_in_worktree = None
  ; sid_state_ready = None
  ; sid_uptime = None
  ; sid_sse_clients = None
  ; sid_gc = None
  ; sid_scheduler = None
  ; sid_operator_action = None
  }

(* The cards say why the server identity gave them nothing: no probe has
   answered, the probe failed, or it answered without the GC and scheduler
   blocks. Each probe is stored the way a refresh stores it. *)
let test_identity_gap_tells_a_failed_probe_from_one_not_made () =
  let unknown =
    testable
      (fun ppf gap -> Format.pp_print_string ppf (Masc_tui_value.Unknown.glyph gap))
      ( = )
  in
  let state = make_state () in
  let gap () = Render_metrics.identity_gap state in
  check unknown "no probe yet" Masc_tui_value.Unknown.Unread (gap ());
  Types.store_server_identity_reading state
    (Error "server identity load failed: connection refused");
  check unknown "failed probe" Masc_tui_value.Unknown.Read_failed (gap ());
  Types.store_server_identity_reading state (Ok (identity_without_blocks ()));
  check unknown "probe without the blocks" Masc_tui_value.Unknown.Unreported (gap ());
  Types.store_server_identity_reading state
    (Error "server identity load failed: timed out");
  check unknown "a later failure replaces the earlier reading"
    Masc_tui_value.Unknown.Read_failed (gap ())

(* The scheduler card's mark says which kind of state the probe is in. A
   probe that raised failed, so it is the failure mark, not the paused one a
   cancelled probe takes (RFC tui-one-screen-grammar section 7.2). *)
let test_a_probe_that_raised_is_marked_failed () =
  let symbol =
    testable
      (fun ppf -> function
         | Masc_tui_card.Mark mark ->
           Format.pp_print_string ppf (Masc_tui_value.Mark.glyph mark)
         | Masc_tui_card.Unknown why ->
           Format.fprintf ppf "unknown %s" (Masc_tui_value.Unknown.glyph why))
      ( = )
  in
  List.iter
    (fun (label, probe, expected) ->
       check symbol label expected (Render_metrics.scheduler_probe_symbol probe))
    [ ( "stopped"
      , Some (Decode.Probe_reported (Scheduler_lag.Stopped "Failure(\"boom\")"))
      , Masc_tui_card.Mark Masc_tui_value.Mark.Failed )
    ; ( "cancelled"
      , Some (Decode.Probe_reported Scheduler_lag.Cancelled)
      , Masc_tui_card.Mark Masc_tui_value.Mark.Paused )
    ; ( "running"
      , Some (Decode.Probe_reported Scheduler_lag.Running)
      , Masc_tui_card.Mark Masc_tui_value.Mark.Under_way )
    ; ( "not started"
      , Some (Decode.Probe_reported Scheduler_lag.Not_started)
      , Masc_tui_card.Mark Masc_tui_value.Mark.Waiting )
    ; ( "a word this build does not know"
      , Some (Decode.Probe_unknown "warming")
      , Masc_tui_card.Unknown Masc_tui_value.Unknown.Unreported )
    ; ( "no probe"
      , None
      , Masc_tui_card.Unknown Masc_tui_value.Unknown.Unreported )
    ]

(* A stopped probe's reason was part of the card edge's status word, which a
   narrow edge drops whole, and the body's probe row had gone: at the
   narrowest cards the reason was nowhere. The edge word is now the state
   alone -- the same word whatever the probe raised -- and the reason is the
   body's, for a stopped probe only. *)
let test_a_stopped_probe_writes_its_reason_in_the_body () =
  let stopped reason = Some (Decode.Probe_reported (Scheduler_lag.Stopped reason)) in
  List.iter
    (fun ko ->
       let word probe = (Render_metrics.scheduler_probe_status ~ko ~tone:"" probe).word in
       check string "the edge word does not carry the reason"
         (word (stopped "Failure(\"boom\")"))
         (word (stopped "Invalid_argument(\"a much longer exception message\")")))
    [ true; false ];
  check (option string) "the body has the reason" (Some "Failure(\"boom\")")
    (Render_metrics.scheduler_stop_reason (stopped "Failure(\"boom\")"));
  List.iter
    (fun (label, probe) ->
       check (option string) label None (Render_metrics.scheduler_stop_reason probe))
    [ "running", Some (Decode.Probe_reported Scheduler_lag.Running)
    ; "not started", Some (Decode.Probe_reported Scheduler_lag.Not_started)
    ; "cancelled", Some (Decode.Probe_reported Scheduler_lag.Cancelled)
    ; "a word this build does not know", Some (Decode.Probe_unknown "warming")
    ; "no probe", None
    ]

(* The fleet row draws how many keepers are configured and how many are
   paused. It used to draw the unpaused ones and leave the reader to
   subtract, and the subtraction is where the bug was: the count skipped a
   declared keeper as well as a paused one, so every declared keeper sat
   inside the difference a reader reads as paused. A declared keeper is not
   paused -- [Tui_decode.keeper_of_declaration] writes [k_paused = false] and
   is the only place a keeper with that origin is built. *)
let make_declared_keeper name : Decode.keeper =
  { (make_keeper name) with k_origin = Decode.Declared_keeper [] }
;;

let test_a_declared_keeper_is_not_counted_as_paused () =
  let state = make_state () in
  state.keepers <-
    [ make_keeper "persisted"
    ; make_keeper ~paused:true "stopped"
    ; make_declared_keeper "declared" ];
  let kpis = Render_metrics.calculate_kpis state in
  check int "three are configured" 3 kpis.total_keepers;
  check int "one of them is paused" 1 kpis.paused_keepers
;;

let test_calculate_kpis_populated () =
  let state = make_state () in
  state.keepers <- [ make_keeper "running"; make_keeper ~paused:true "idle" ];
  state.keeper_turns <-
    [ { Decode.ktr_chat_control_token = None; ktr_keeper_name = "running";
        ktr_state = Keeper_turn_running { lane = Turn_lane_autonomous; started_at_unix = 1.; interrupt_token = "fixture-token"; turn_ref = None; preview = None } };
      { Decode.ktr_chat_control_token = None; ktr_keeper_name = "idle"; ktr_state = Keeper_turn_idle };
      { Decode.ktr_chat_control_token = None; ktr_keeper_name = "unknown"; ktr_state = Keeper_turn_unavailable "owner unavailable" } ];
  state.keeper_turns_observed_at <- Some 100.;
  let kpis = Render_metrics.calculate_kpis state in
  check int "paused is a configuration count" 1 kpis.paused_keepers;
  let turns = Option.get kpis.turns in
  check int "only actual running owners count as running" 1 turns.running;
  check int "idle is distinct" 1 turns.idle;
  check int "unavailable is distinct" 1 turns.unavailable;
  state.keeper_turns_error <- Some (Types.Request_failed "keeper turns load failed: HTTP 503");
  check bool "stale rows do not remain a current count" true
    (Option.is_none (Render_metrics.calculate_kpis state).turns);
  let output = String.concat "\n" (Render_metrics.render_section_resources ~cols:160 state) in
  check bool "failed observation is visible" true
    (contains output "keeper turns load failed: HTTP 503");
  check bool "the render does not add a second failure verdict" false
    (contains output "Current turn observation failed");
  check bool "elapsed rows are not advanced as current on failure" false (contains output "lane autonomous")
;;

let test_retained_task_outcomes () =
  let now = Option.get (Masc_domain.parse_iso8601_opt "2026-09-07T12:00:00Z") in
  let task id created_at status = domain_task ~id ~created_at ~status in
  let done_at at = Masc_domain.Done { assignee = "producer"; completed_at = at; notes = None } in
  let tasks =
    [ task "old-completed" "2026-09-01T00:00:00Z" (done_at "2026-09-07T11:00:00Z");
      task "submitted" "2026-09-07T10:00:00Z"
        (AwaitingVerification { assignee = "producer"; started_at = "2026-09-07T10:00:00Z";
          submitted_at = "2026-09-07T11:00:00Z"; verification_id = "proof" });
      task "boundary" "2026-09-06T12:00:00Z" Todo;
      task "cancelled" "2026-09-07T09:00:00Z"
        (Cancelled { cancelled_by = "producer"; cancelled_at = "2026-09-07T11:30:00Z"; reason = None });
      task "older-done" "2026-09-01T00:00:00Z" (done_at "2026-09-05T10:00:00Z");
      task "invalid" "invalid timestamp" Todo;
      task "future" "2026-09-08T10:00:00Z" Todo ]
  in
  let flow = Masc_tui_task_flow.of_tasks ~now ~archived:Masc_tui_task_flow.Archived.empty tasks in
  check int "new registrations in the window" 3 flow.recent.created;
  check int "completion is independent of creation time" 1 flow.recent.completed;
  check int "cancellation is separate" 1 flow.recent.cancelled;
  check int "retained done includes old outcomes" 2 flow.current.completed;
  check int "verification pending is not done" 1 flow.current.awaiting_verification;
  check int "open includes pending and invalid-date tasks" 4 (Masc_tui_task_flow.open_count flow.current);
  check int "invalid timestamp count retained" 1 flow.unparseable_timestamps;
  check (option (float 0.001)) "oldest open registration" (Some (now -. 86400.)) flow.oldest_open_created_at;
  let state = make_state () in
  state.task_flow <- Some flow;
  state.tasks <- [];
  state.tasks_error <- Some "goal links unavailable";
  let kpis = Render_metrics.calculate_kpis state in
  check int "active-only list does not erase completed outcomes" 2 (Option.get kpis.tasks).completed;
  let output = String.concat "\n" (Render_metrics.render_section_resources ~cols:160 state) in
  (* The window is drawn in the operator's zone, so the expected start is
     drawn by the same notation rather than spelled in UTC. *)
  let window_start =
    Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_minute
      ~now:(Unix.gettimeofday ()) flow.window_started_at
  in
  check bool "snapshot window is explicit" true
    (contains_plain output ("Window: " ^ window_start ^ " to "));
  check bool "source warning does not erase known counts" true
    (contains_plain output "New tasks 3 · Done 1 · Cancelled 1");
  check bool "source warning is visible" true
    (contains_plain output "goal links unavailable");
  check bool "old glow cache is not presented as history" false (contains output "Heatmap")
;;

let test_tasks_error_is_sanitized () =
  let control = "\027[2J" in
  let error = "boom " ^ control ^ " wiped" in
  let state = make_state () in
  state.task_flow <- None;
  state.tasks_error <- Some error;
  let output =
    String.concat "\n" (Render_metrics.render_section_resources ~cols:160 state)
  in
  check bool "the no-snapshot line does not carry the raw control sequence" false
    (contains output control);
  check bool "the no-snapshot line escapes it instead" true
    (contains output "\\x1B[2J");
  check bool "the error text is still visible" true (contains output "boom");
  let flow =
    Masc_tui_task_flow.of_tasks ~now:(Unix.gettimeofday ()) ~archived:Masc_tui_task_flow.Archived.empty []
  in
  let state = make_state () in
  state.task_flow <- Some flow;
  state.tasks_error <- Some error;
  let output =
    String.concat "\n" (Render_metrics.render_section_resources ~cols:160 state)
  in
  check bool "the snapshot warning does not carry the raw control sequence" false
    (contains output control);
  check bool "the snapshot warning escapes it instead" true
    (contains output "\\x1B[2J")
;;

let test_assignee_work_and_daily_flow () =
  let now = Option.get (Masc_domain.parse_iso8601_opt "2026-09-12T00:00:00Z") in
  let task id created_at status = domain_task ~id ~created_at ~status in
  let done_by who at = Masc_domain.Done { assignee = who; completed_at = at; notes = None } in
  let tasks =
    [ (* Two completions two and four hours wide: an even sample count has to
         average the middle pair rather than pick a side. *)
      task "r1" "2026-09-10T00:00:00Z" (done_by "matrix-reader" "2026-09-10T02:00:00Z");
      task "r2" "2026-09-10T00:00:00Z" (done_by "matrix-reader" "2026-09-10T04:00:00Z");
      (* The agent spelling of the same keeper. RFC-0393 removed the suffix
         strip, so this must stay its own row. *)
      task "a1" "2026-09-11T00:00:00Z" (done_by "keeper-matrix-reader-agent" "2026-09-11T06:00:00Z");
      task "o1" "2026-09-11T00:00:00Z"
        (Claimed { assignee = "matrix-reader"; claimed_at = "2026-09-11T01:00:00Z" });
      (* Todo carries no assignee and must not invent one. *)
      task "t1" "2026-09-11T00:00:00Z" Todo;
      (* [cancelled_by] answers who cancelled, not who held the task. *)
      task "c1" "2026-09-11T00:00:00Z"
        (Cancelled { cancelled_by = "polisher"; cancelled_at = "2026-09-11T05:00:00Z";
          reason = None }) ]
  in
  let flow = Masc_tui_task_flow.of_tasks ~now ~archived:Masc_tui_task_flow.Archived.empty tasks in
  let rows = flow.by_assignee in
  check int "only states that carry an assignee open a row" 2 (List.length rows);
  let row name =
    List.find (fun (r : Masc_tui_task_flow.assignee_flow) -> r.af_assignee = name) rows
  in
  check bool "a cancelled task does not attribute work to the canceller" false
    (List.exists (fun (r : Masc_tui_task_flow.assignee_flow) -> r.af_assignee = "polisher") rows);
  let matrix_reader = row "matrix-reader" in
  check int "completed tasks counted" 2 matrix_reader.af_done;
  check int "claimed work counted as open" 1 matrix_reader.af_open;
  check (option (float 0.001)) "even sample count averages the middle pair"
    (Some 3.0) matrix_reader.af_median_lead_hours;
  let agent = row "keeper-matrix-reader-agent" in
  check int "the agent spelling keeps its own completions" 1 agent.af_done;
  check (option (float 0.001)) "a single sample is its own median"
    (Some 6.0) agent.af_median_lead_hours;
  check string "the longer queue sorts first" "matrix-reader"
    (List.hd rows).af_assignee;
  let days = flow.daily in
  check int "the span is the declared number of days" Masc_tui_task_flow.daily_days
    (List.length days);
  let day_from_end back = List.nth days (Masc_tui_task_flow.daily_days - back) in
  let today = day_from_end 1 in
  check int "the span ends on the observation day" 0 today.d_created;
  let yesterday = day_from_end 2 in
  check int "creations land on their own day" 4 yesterday.d_created;
  check int "completions land on their own day" 1 yesterday.d_completed;
  check int "cancellations stay separate from completions" 1 yesterday.d_cancelled;
  let before = day_from_end 3 in
  check int "an earlier day keeps its own creations" 2 before.d_created;
  check int "an earlier day keeps its own completions" 2 before.d_completed;
  let quiet = day_from_end Masc_tui_task_flow.daily_days in
  check int "a day with no activity is present as zero" 0 quiet.d_created;
  let state = make_state () in
  state.task_flow <- Some flow;
  let output = String.concat "\n" (Render_metrics.render_section_resources ~cols:160 state) in
  check bool "the per-assignee table is drawn" true (contains output "median lead");
  check bool "the keeper spelling is listed" true (contains output "matrix-reader");
  check bool "the agent spelling is listed beside it" true
    (contains output "keeper-matrix-reader-agent");
  check bool "the span names its last day" true (contains output "09-12");
  check bool "creations are a row of their own" true (contains output "created");
  check bool "cancellations are a row of their own" true (contains output "cancelled");
  check bool "lead time is not presented as work time" false (contains output "work time")
;;

(* [masc_gc] moves finished tasks into the archive. Their days still
   happened, so the day bars count them; the board counts and the assignee
   rows describe what is live, so they do not. A task restored to the
   backlog but still in the archive is counted once (#38542). *)
let test_archived_tasks_count_in_the_day_bars_only () =
  let now = Option.get (Masc_domain.parse_iso8601_opt "2026-09-12T00:00:00Z") in
  let task id created_at status = domain_task ~id ~created_at ~status in
  let done_by who at = Masc_domain.Done { assignee = who; completed_at = at; notes = None } in
  let live = [ task "live" "2026-09-11T00:00:00Z" (done_by "matrix-reader" "2026-09-11T02:00:00Z") ] in
  let archived =
    [ task "gone" "2026-09-02T00:00:00Z" (done_by "matrix-reader" "2026-09-03T00:00:00Z");
      (* Restored to the backlog, still in the archive: counted once. *)
      task "live" "2026-09-11T00:00:00Z" (done_by "matrix-reader" "2026-09-11T02:00:00Z") ]
  in
  let archived =
    List.fold_left Masc_tui_task_flow.Archived.add Masc_tui_task_flow.Archived.empty archived
  in
  let flow = Masc_tui_task_flow.of_tasks ~now ~archived live in
  let completed_in_span =
    List.fold_left (fun n (d : Masc_tui_task_flow.day) -> n + d.d_completed) 0 flow.daily
  in
  check int "the archived completion lands on its day, the restored one once" 2
    completed_in_span;
  check int "the board count is the backlog's" 1 flow.current.completed;
  check int "the assignee row is the backlog's" 1
    (List.hd flow.by_assignee).af_done
;;

let test_assignee_rows_capped () =
  let now = Option.get (Masc_domain.parse_iso8601_opt "2026-09-12T00:00:00Z") in
  let task id created_at status = domain_task ~id ~created_at ~status in
  let tasks =
    List.init 13 (fun index ->
      let who = Printf.sprintf "holder-%02d" index in
      task (Printf.sprintf "t%02d" index) "2026-09-11T00:00:00Z"
        (Masc_domain.Claimed { assignee = who; claimed_at = "2026-09-11T01:00:00Z" }))
  in
  let flow = Masc_tui_task_flow.of_tasks ~now ~archived:Masc_tui_task_flow.Archived.empty tasks in
  check int "every assignee is retained in the snapshot" 13 (List.length flow.by_assignee);
  let state = make_state () in
  state.task_flow <- Some flow;
  let output = String.concat "\n" (Render_metrics.render_section_resources ~cols:160 state) in
  check bool "the tail is reported rather than dropped" true
    (contains_plain output "    3 more")
;;

let test_approval_source_observations () =
  let state = make_state () in
  (* A successful read of the workspace cannot establish approval source data. *)
  state.local_keepers <- Types.Local_workspace_read;
  let kpis = Render_metrics.calculate_kpis state in
  check (option int) "unread Gate is not zero" None kpis.gate_pending_count;
  check (option int) "unread held calls are not zero" None kpis.held_approvals_count;
  let governance () = String.concat "\n" (Render_metrics.render_section_tools ~cols:120 state) in
  let output = governance () in
  check bool "first read stays explicit" true
    (contains_plain output "Pending Gate Calls: not loaded");
  check bool "unread queues cannot claim empty" false
    (contains_plain output "no active pending");
  state.gate_snapshot_observed <- true;
  state.keeper_tool_approvals_observed <- true;
  let kpis = Render_metrics.calculate_kpis state in
  check (option int) "observed empty Gate is zero" (Some 0) kpis.gate_pending_count;
  check (option int) "observed empty held calls are zero" (Some 0) kpis.held_approvals_count;
  check bool "both observed queues may claim empty" true
    (contains_plain (governance ()) "no active pending");
  state.gate_pending <- [ make_gate_pending ~id:"gp1" ~keeper:"alpha" ];
  state.gate_error <- Some "gate-refresh-offline";
  let kpis = Render_metrics.calculate_kpis state in
  check (option int) "stale Gate count is not current" None kpis.gate_pending_count;
  check (option int) "available held count survives" (Some 0) kpis.held_approvals_count;
  let output = governance () in
  check bool "stale source error is visible" true
    (contains_plain output "gate-refresh-offline");
  check bool "stale tool is not charted" false (contains_plain output "bash");
  check bool "partial empty cannot claim all empty" false
    (contains_plain output "no active pending");
  state.gate_error <- None;
  state.gate_rules_unavailable <- Some "rules-store-offline";
  check (option int) "rules failure does not hide ready queue" (Some 1)
    (Render_metrics.calculate_kpis state).gate_pending_count;
  let output = governance () in
  check bool "partial store error is visible" true
    (contains_plain output "Standing Rules: load failed: rules-store-offline");
  check bool "available tool is charted" true (contains_plain output "bash")
;;

let escape = "\027[31m"

let drawn lines = String.concat "\n" lines

let test_the_tools_section_escapes_the_word_it_counts_by () =
  let state = make_state () in
  let gp =
    { (make_gate_pending ~id:"gp1" ~keeper:"alpha") with
      Decode.gp_display_tool = "bash" ^ escape ^ "red"
    }
  in
  state.gate_pending <- [ gp ];
  state.gate_snapshot_observed <- true;
  let output = drawn (Render_metrics.render_section_tools ~cols:90 state) in
  check bool "the chart's label carries no escape" false (contains output escape)

(* The Keeper id is drawn by the same section, fitted to sixteen cells.
   Fitting is not escaping. *)
let test_the_tools_section_escapes_a_keeper_id () =
  let state = make_state () in
  let kh =
    make_keeper_health ~keeper_id:("alpha" ^ escape) ~facts:25
      ~snapshot_bytes:4096
  in
  state.memory_health <-
    Some (make_memory_health ~total_facts:25 ~source_facts:0 ~keepers:[ kh ]);
  let output = drawn (Render_metrics.render_section_tools ~cols:90 state) in
  check bool "the fitted id carries none either" false (contains output escape)

(* The probe word reaches three rows through one reader, so it is escaped
   there rather than at each row. *)
let test_the_fleet_section_escapes_the_probe_word () =
  let state = make_state () in
  state.server_identity <-
    Some
      { Decode.sid_version = "0.0.0"
      ; sid_binary_commit = "deadbeef"
      ; sid_binary_commit_age_s = None; sid_runtime_instance_id = None
      ; sid_base_path = Masc.Tui_decode.Canonical_path.of_path "/tmp"
      ; sid_masc_root = Masc.Tui_decode.Canonical_path.of_path "/tmp"
      ; sid_executable_in_worktree = None
      ; sid_state_ready = None
      ; sid_uptime = None
      ; sid_sse_clients = None
      ; sid_gc = None
      ; sid_scheduler =
          Some
            { Decode.ssch_probe = Some (Decode.Probe_unknown ("running" ^ escape))
            ; ssch_samples = 0
            ; ssch_p50_ms = 0.
            ; ssch_p95_ms = 0.
            ; ssch_p99_ms = 0.
            ; ssch_max_ms = 0.
            ; ssch_mean_ms = 0.
            ; ssch_stalls = 0
            ; ssch_pool_domains = None
            }
      ; sid_operator_action = None
      };
  let output = drawn (Render_metrics.render_section_fleet ~cols:90 state) in
  check bool "the probe row carries no escape" false (contains output escape)

(* The engine graphs read [/health] only while Telemetry's engine section is
   on screen; anywhere else the loop samples nothing (RFC
   tui-one-screen-grammar section 5.6). *)
let test_the_engine_graphs_sample_only_on_the_engine_view () =
  let wide = 160 and compact = 100 in
  let state = make_state () in
  let sampled () = Option.is_some (Render_metrics.engine_graph_capacity ~cols:wide state) in
  check bool "another screen" false (sampled ());
  state.Types.view <- Types.Metrics;
  check bool "Usage without Telemetry" false (sampled ());
  state.Types.usage_telemetry_open <- true;
  state.Types.metrics_section <- Types.Section_fleet;
  check bool "the engine section" true (sampled ());
  check bool "the engine section without room for cards" true
    (Option.is_some (Render_metrics.engine_graph_capacity ~cols:compact state));
  state.Types.metrics_section <- Types.Section_resources;
  check bool "the work section" false (sampled ());
  state.Types.metrics_section <- Types.Section_tools;
  check bool "the memory and Gate section" false (sampled ());
  state.Types.metrics_section <- Types.Section_fleet;
  state.Types.usage_telemetry_open <- false;
  check bool "Telemetry closed again" false (sampled ())

(* The TUI session log as [state.events] holds it, newest first. The newest
   event is the long kind the loader writes when the feed closes: the subject
   first, then the cause, then what to do. *)
let session_width = 40

(* A fixed instant, so every event is the same day as [session_now] in any
   zone the test runs in and the clock beside it keeps one width. *)
let session_now = 1_700_000_000.

let session_log =
  let event minutes_ago content =
    { Types.at = session_now -. (60. *. minutes_ago); event_type = "observer"; content } in
  [ event 0.
      ("runtime event feed closed: the server refused the subscription because \
        the operator token expired; run masc login for this workspace and \
        press r to open the feed again")
  ; event 1. "keeper alpha started"
  ; event 2. "keeper beta paused by the operator"
  ; event 3. "workspace declaration saved"
  ; event 4. "approval queue read"
  ]

let rows_of (entry : Render_metrics.session_entry) = List.length entry.rows

let rows_used (block : Render_metrics.session_block) =
  (if block.earlier > 0 then 1 else 0)
  + List.fold_left (fun used entry -> used + rows_of entry) 0 block.kept

let rec drop count list =
  match count, list with
  | 0, _ | _, [] -> list
  | count, _ :: rest -> drop (count - 1) rest

(* What the block decides with a room, read against every event drawn
   without one: the kept events are the newest ones with every row they
   take, and they and the count fit the room, unless the newest alone is
   taller. No older event would have fit as well. *)
let check_session_room room =
  let whole = Render_metrics.session_block ~now:session_now ~width:session_width session_log in
  let block =
    Render_metrics.session_block ~now:session_now ~width:session_width ~room session_log in
  let total = List.length whole.kept in
  check int "unbounded, nothing is left out" 0 whole.earlier;
  check int "every folded event is kept or counted" total
    (block.earlier + List.length block.kept);
  check bool "the kept events are the newest, each with all of its rows" true
    (drop block.earlier whole.kept = block.kept);
  (match block.kept with
   | [ _ ] -> ()
   | [] | _ :: _ :: _ ->
     check bool "the kept events and the count fit the room" true
       (rows_used block <= room));
  if block.earlier > 0 then
    check bool "the next older event would not have fit" true
      (rows_used block + rows_of (List.nth whole.kept (block.earlier - 1)) > room)

let test_a_long_session_event_takes_the_rows_its_sentence_needs () =
  let block = Render_metrics.session_block ~now:session_now ~width:session_width session_log in
  let newest = List.nth block.kept (List.length block.kept - 1) in
  List.iter
    (fun row ->
       check bool "no row is wider than the block" true
         (Layout.display_width row <= session_width))
    newest.rows;
  check bool "the rows hold the whole sentence rather than its first row" true
    (rows_of newest * session_width >= Layout.display_width newest.event.content)

let test_the_session_room_is_spent_in_rows_on_whole_events () =
  List.iter check_session_room [ 1; 2; 4; 7; 9; 12; 40 ]

let test_the_newest_session_event_is_kept_when_taller_than_the_room () =
  let block =
    Render_metrics.session_block ~now:session_now ~width:session_width ~room:3 session_log in
  check int "the earlier events are counted" 4 block.earlier;
  check bool "the newest is drawn whole past the room" true
    (match block.kept with
     | [ newest ] -> rows_of newest > 3
     | [] | _ :: _ :: _ -> false)

(* The usage diagnostics body hands its window to the title row when the
   section hides lines, and nothing when it shows them all (RFC
   tui-one-screen-grammar, section 2). *)
let test_the_metrics_body_hands_its_window_only_when_it_hides_lines () =
  let state = make_state () in
  let suffix_lines = List.init 60 (Printf.sprintf "line-%02d") in
  let handed ~budget =
    let positions = ref [] in
    Render_metrics.render_metrics_body ~cols:100 ~budget ~suffix_lines state
      ~report_scroll:(fun _ _ _ -> ())
      ~hand_position:(fun position -> positions := position :: !positions)
      ~push:ignore ~push_styled:(fun ~style:_ _ -> ()) ~push_selected:ignore
      ~push_divider:ignore ~push_empty:ignore;
    !positions
  in
  (match handed ~budget:20 with
   | [ Masc_tui_value.Position.Window { first; last; total } ] ->
       check int "the window starts at the top" 1 first;
       check bool "the window ends inside what it hides" true (last < total);
       check bool "the total counts the hidden lines" true (total >= 60)
   | [] -> fail "a body that hides lines hands its window"
   | [ Masc_tui_value.Position.(Row _ | Partial _) ] | _ :: _ :: _ ->
       fail "the body hands one window and no row");
  check int "a body that shows every line hands nothing" 0
    (List.length (handed ~budget:400))

let test_kpi_layout_responsive_tiers () =
  check bool "below 80 cols falls back to Compact" true
    (Render_metrics.kpi_layout ~cols:79 = Render_metrics.Compact);
  (match Render_metrics.kpi_layout ~cols:80 with
   | Render_metrics.Cards_2x2 { card_cells; _ } ->
       check bool "80 cols 2x2 card has >= 32 text cells" true (card_cells >= 32)
   | Cards_4 _ | Compact -> fail "expected Cards_2x2 at cols=80");
  (match Render_metrics.kpi_layout ~cols:120 with
   | Render_metrics.Cards_2x2 { card_cells; _ } ->
       check bool "120 cols 2x2 card has >= 32 text cells" true (card_cells >= 32)
   | Cards_4 _ | Compact -> fail "expected Cards_2x2 at cols=120");
  (match Render_metrics.kpi_layout ~cols:155 with
   | Render_metrics.Cards_2x2 { card_cells; _ } ->
       check bool "155 cols 2x2 card has >= 32 text cells" true (card_cells >= 32)
   | Cards_4 _ | Compact -> fail "expected Cards_2x2 at cols=155");
  (match Render_metrics.kpi_layout ~cols:156 with
   | Render_metrics.Cards_4 { card_cells; _ } ->
       check bool "156 cols 4x1 card has >= 32 text cells" true (card_cells >= 32)
   | Cards_2x2 _ | Compact -> fail "expected Cards_4 at cols=156")

let test_layer6_numbered_pills_and_resource_charts () =
  let pills = Render_metrics.section_pills_line ~ko:false ~cols:120 ~active:Types.Section_fleet in
  check bool "section pills show superscript digits 1-3" true
    (contains pills "\xc2\xb9" && contains pills "\xc2\xb2" && contains pills "\xc2\xb3");
  let now = Option.get (Masc_domain.parse_iso8601_opt "2026-09-12T00:00:00Z") in
  let task id created_at status = domain_task ~id ~created_at ~status in
  let done_by who at = Masc_domain.Done { assignee = who; completed_at = at; notes = None } in
  let tasks =
    [ task "t1" "2026-09-11T00:00:00Z" (done_by "alice" "2026-09-11T02:00:00Z")
    ; task "t2" "2026-09-11T00:00:00Z" (Masc_domain.InProgress { assignee = "alice"; started_at = "2026-09-11T03:00:00Z" })
    ; task "t3" "2026-09-11T00:00:00Z" Masc_domain.Todo
    ]
  in
  let flow = Masc_tui_task_flow.of_tasks ~now ~archived:Masc_tui_task_flow.Archived.empty tasks in
  let state = make_state () in
  state.task_flow <- Some flow;
  let rows = Render_metrics.render_section_resources ~cols:120 state in
  let output = String.concat "\n" rows in
  check bool "section_resources uses hairline rule headers" true
    (contains output "\xe2\x94\x80\xe2\x94\x80");
  check bool "section_resources draws open-task distribution bars" true
    (contains output "%)" && contains output "\xe2\x96\xa0");
  let has_braille row =
    contains row "\xe2\xa0" || contains row "\xe2\xa1"
    || contains row "\xe2\xa2" || contains row "\xe2\xa3"
  in
  check bool "section_resources renders 3-row continuous done trend with Braille dots" true
    (match List.find_index (fun r -> contains r "done trend") rows with
     | Some idx when idx + 2 < List.length rows ->
         let r1 = List.nth rows (idx + 1)
         and r2 = List.nth rows (idx + 2) in
         String.length r1 > 15 && String.length r2 > 15
         && has_braille r1 && has_braille r2
     | Some _ | None -> false)
;;

let () =
  run "tui_render_metrics"
    [ ( "connection"
      , [ test_case "compact state preserves workspace and read failures" `Quick
            test_compact_connection_priority ] )
    ; ( "scroll"
      , [ test_case "card reflow preserves the reading position" `Quick
            test_metrics_scroll_tracks_card_reflow ] )
    ; ( "kpis"
      , [ test_case "calculate_kpis_empty" `Quick test_calculate_kpis_empty
        ; test_case "a failed identity probe is not drawn as one not made" `Quick
            test_identity_gap_tells_a_failed_probe_from_one_not_made
        ; test_case "a probe that raised is marked failed" `Quick
            test_a_probe_that_raised_is_marked_failed
        ; test_case "a stopped probe writes its reason in the body" `Quick
            test_a_stopped_probe_writes_its_reason_in_the_body
        ; test_case "the engine graphs sample only on the engine view" `Quick
            test_the_engine_graphs_sample_only_on_the_engine_view
        ; test_case "calculate_kpis_populated" `Quick test_calculate_kpis_populated
        ; test_case "a declared keeper is not counted as paused" `Quick
            test_a_declared_keeper_is_not_counted_as_paused
        ; test_case "retained task outcomes and observation scope" `Quick test_retained_task_outcomes
        ; test_case "assignee work and daily flow" `Quick test_assignee_work_and_daily_flow
        ; test_case "assignee rows capped" `Quick test_assignee_rows_capped
        ; test_case "archived tasks count in the day bars only" `Quick
            test_archived_tasks_count_in_the_day_bars_only
        ] )
    ; ( "overview_pulse"
      , [] )
    ; ( "section_pills"
      , [ test_case "numbered pills and resource Braille trend + bars" `Quick
            test_layer6_numbered_pills_and_resource_charts
        ] )
    ; ( "sections"
      , [ test_case "the tools section escapes the word it counts by" `Quick
            test_the_tools_section_escapes_the_word_it_counts_by
        ; test_case "the tools section escapes a Keeper id" `Quick
            test_the_tools_section_escapes_a_keeper_id
        ; test_case "the fleet section escapes the probe word" `Quick
            test_the_fleet_section_escapes_the_probe_word
        ; test_case "approval source observations" `Quick test_approval_source_observations
        ;] )
    ; ( "session_block"
      , [ test_case "a long event takes the rows its sentence needs" `Quick
            test_a_long_session_event_takes_the_rows_its_sentence_needs
        ; test_case "the room is spent in rows on whole events" `Quick
            test_the_session_room_is_spent_in_rows_on_whole_events
        ; test_case "the newest event is kept when taller than the room" `Quick
            test_the_newest_session_event_is_kept_when_taller_than_the_room
        ] )
    ; ( "responsiveness"
      , [ test_case "KPI cards step down 4x1 -> 2x2 -> Compact cleanly" `Quick
            test_kpi_layout_responsive_tiers
        ] )
    ; ( "render_body"
      , [ test_case "a Tasks read error is sanitized before it is drawn" `Quick
            test_tasks_error_is_sanitized
        ; test_case "the body hands its window only when it hides lines" `Quick
            test_the_metrics_body_hands_its_window_only_when_it_hides_lines
        ;] )
    ]
;;
