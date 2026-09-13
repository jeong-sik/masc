open Alcotest
module Types = Masc_tui_types
module Decode = Masc.Tui_decode
module Layout = Masc_tui_message_layout
module Render_metrics = Masc_tui_render_metrics

let make_state () =
  Types.create_state ~workspace:"" ~port:0 ~refresh_interval:0. ()
;;

let make_keeper ?(paused = false) name : Decode.keeper =
  { k_origin = Masc.Tui_decode.Persisted_keeper; k_name = name
  ; k_trace_id = "trace-" ^ name
  ; k_paused = paused
  ; k_current_task_id = None
  ; k_total_turns = 10
  ; k_total_tokens = 5000
  ; k_total_cost_usd = 0.05
  ; k_last_turn_ts = "2026-09-05T12:00:00Z"
  ; k_last_proactive_outcome = "success"
  ; k_created_at = "2026-09-01T00:00:00Z"
  ; k_updated_at = "2026-09-05T12:00:00Z"
  }
;;

let make_keeper_health ~keeper_id ~facts ~snapshot_bytes : Decode.memory_keeper_health =
  { mkh_keeper_id = keeper_id
  ; mkh_revision = 1
  ; mkh_updated_at = Some 1700000000.
  ; mkh_facts = facts
  ; mkh_observed_facts = facts - 2
  ; mkh_derived_facts = 2
  ; mkh_support_invalidations = 0
  ; mkh_snapshot_bytes = snapshot_bytes
  ; mkh_added = facts
  ; mkh_removed = 0
  ; mkh_snapshot_present = true
  ; mkh_librarian_lane_busy = 0
  ; mkh_librarian_failures = 0
  ; mkh_vision_ingest_errors = 0
  ; mkh_vision_ingest_error_reasons = []
  ; mkh_read_error = None
  ; mkh_source_revision = 0
  ; mkh_source_facts = 0
  ; mkh_source_invalidations = 0
  ; mkh_source_snapshot_bytes = 0
  ; mkh_source_snapshot_present = false
  ; mkh_source_read_error = None
  ; mkh_alerts = []
  }
;;

let make_memory_health ~total_facts ~source_facts ~keepers : Decode.memory_health_snapshot =
  { mhs_generated_at = 1000.0
  ; mhs_keepers = keepers
  ; mhs_total_facts = total_facts
  ; mhs_total_observed_facts = total_facts - source_facts
  ; mhs_total_derived_facts = 0
  ; mhs_total_support_invalidations = 0
  ; mhs_total_snapshot_bytes = 4096
  ; mhs_total_source_facts = source_facts
  ; mhs_total_source_invalidations = 0
  ; mhs_total_source_snapshot_bytes = 1024
  ; mhs_total_librarian_failures = 0
  ; mhs_total_vision_ingest_errors = 0
  ; mhs_total_read_errors = 0
  ; mhs_total_source_read_errors = 0
  ; mhs_warn_alerts = 0
  ; mhs_error_alerts = 0
  ; mhs_starving_keepers = 0
  }
;;

let make_gate_pending ~id ~keeper : Decode.gate_pending =
  { gp_id = id
  ; gp_keeper = keeper
  ; gp_operation = "tool_execute"
  ; gp_display_tool = "bash"
  ; gp_input_preview = Some "echo test"
  ; gp_execution_cwd = None
  ; gp_execution_sandbox = None
  ; gp_waiting_s = Some 10.0
  ; gp_phase = Decode.Gate_queued
  ; gp_auto_judge_detail = None
  ; gp_retry_request = None
  }
;;

let contains text needle =
  try ignore (Str.search_forward (Str.regexp_string needle) text 0); true
  with Not_found -> false

let domain_task ~id ~created_at ~status : Masc_domain.task =
  { id; title = id; description = ""; task_status = status; priority = 3;
    files = []; created_at; created_by = Some "producer";
    predecessor_task_id = None; contract = None;
    execution_links = Masc_domain.no_execution_links; handoff_context = None;
    cycle_count = 0; reclaim_policy = None; do_not_reclaim_reason = None; skills = [] }

let test_calculate_kpis_empty () =
  let state = make_state () in
  let kpis = Render_metrics.calculate_kpis state in
  check bool "unobserved tasks stay unknown" true (Option.is_none kpis.tasks);
  check bool "unobserved turns stay unknown" true (Option.is_none kpis.turns);
  let output = String.concat "\n" (Render_metrics.render_section_fleet ~cols:160 state) in
  check bool "missing GC is visible" true (contains output "GC telemetry not observed");
  check bool "missing scheduler is visible" true (contains output "Scheduler telemetry not observed");
  check bool "no fabricated heap" false (contains output "42.5");
  check bool "no fabricated latency" false (contains output "0.82")
;;

let test_calculate_kpis_populated () =
  let state = make_state () in
  state.keepers <- [ make_keeper "running"; make_keeper ~paused:true "idle" ];
  state.keeper_turns <-
    [ { Decode.ktr_keeper_name = "running";
        ktr_state = Keeper_turn_running { lane = Turn_lane_autonomous; started_at_unix = 1.; interrupt_token = None; preview = None } };
      { Decode.ktr_keeper_name = "idle"; ktr_state = Keeper_turn_idle };
      { Decode.ktr_keeper_name = "unknown"; ktr_state = Keeper_turn_unavailable "owner unavailable" } ];
  state.keeper_turns_observed_at <- Some 100.;
  let kpis = Render_metrics.calculate_kpis state in
  check int "unpaused is a configuration count" 1 kpis.unpaused_keepers;
  let turns = Option.get kpis.turns in
  check int "only actual running owners count as running" 1 turns.running;
  check int "idle is distinct" 1 turns.idle;
  check int "unavailable is distinct" 1 turns.unavailable;
  state.keeper_turns_error <- Some "poll failed";
  check bool "stale rows do not remain a current count" true
    (Option.is_none (Render_metrics.calculate_kpis state).turns);
  let output = String.concat "\n" (Render_metrics.render_section_resources ~cols:160 state) in
  check bool "failed observation is visible" true (contains output "poll failed");
  check bool "elapsed rows are not advanced as current on failure" false (contains output "lane autonomous")
;;

let test_scheduler_sample_availability () =
  List.iter
    (fun (samples, probe, displayed_probe) ->
      let state = make_state () in
      let payload =
        `Assoc
          [ ("status", `String "ok")
          ; ("scheduler", `Assoc
              [ ("samples", `Int samples)
              ; ("probe", `String probe)
              ; ("pool_domains", `Int 3)
              ; ("p95_ms", `Float 512.125)
              ; ("stalls", `Int 7)
              ])
          ]
      in
      state.server_identity <- Some
        (match Decode.decode_server_identity payload with
         | Ok identity -> identity
         | Error detail -> fail detail);
      state.metrics_section <- Types.Section_fleet;
      let lines = ref [] in
      let push line = lines := line :: !lines in
      Render_metrics.render_metrics_body ~cols:200 ~budget:40 state
        ~report_scroll:(fun _ -> ())
        ~push ~push_styled:(fun ~style:_ line -> push line)
        ~push_selected:push ~push_divider:(fun () -> ())
        ~push_empty:(fun () -> ());
      let output = String.concat "\n" (List.rev !lines) in
      let measured = samples > 0 in
      check bool "measured p95 requires a positive sample count" measured
        (contains output "p95 512.125");
      check bool "stall count requires a positive sample count" measured
        (contains output "stalls");
      check bool "sample absence is explicit" (not measured)
        (contains output "No latency samples in the producer window");
      check bool "domain observation remains visible in detail" true
        (contains output "worker domains 3");
      if not measured then (
        check bool "card explains absent samples" true
          (contains output "No latency samples");
        check bool "card preserves normalized probe observation" true
          (contains output ("Probe: " ^ displayed_probe));
        check bool "detail preserves normalized probe observation" true
          (contains output ("Probe " ^ displayed_probe))))
    [ (0, "running", "running")
    ; (0, "", "unreported")
    ; (-1, " \t ", "unreported")
    ; (1, "running", "running")
    ]
;;

let test_retained_task_outcomes () =
  let now = Option.get (Masc_domain.parse_iso8601_opt "2026-09-07T12:00:00Z") in
  let task id created_at status = domain_task ~id ~created_at ~status in
  let done_at at = Masc_domain.Done { assignee = "producer"; completed_at = at; notes = None } in
  let tasks =
    [ task "old-completed" "2026-09-01T00:00:00Z" (done_at "2026-09-07T11:00:00Z");
      task "submitted" "2026-09-07T10:00:00Z"
        (AwaitingVerification { assignee = "producer"; started_at = "2026-09-07T10:00:00Z";
          submitted_at = "2026-09-07T11:00:00Z"; intent = Complete_task; verification_id = "proof" });
      task "boundary" "2026-09-06T12:00:00Z" Todo;
      task "cancelled" "2026-09-07T09:00:00Z"
        (Cancelled { cancelled_by = "producer"; cancelled_at = "2026-09-07T11:30:00Z"; reason = None });
      task "older-done" "2026-09-01T00:00:00Z" (done_at "2026-09-05T10:00:00Z");
      task "invalid" "invalid timestamp" Todo;
      task "future" "2026-09-08T10:00:00Z" Todo ]
  in
  let flow = Masc_tui_task_flow.of_tasks ~now tasks in
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
  check bool "snapshot window is explicit" true (contains output "2026-09-06 12:00 UTC");
  check bool "source warning does not erase known counts" true (contains output "New tasks 3 · Done 1 · Cancelled 1");
  check bool "source warning is visible" true (contains output "goal links unavailable");
  check bool "old glow cache is not presented as history" false (contains output "Heatmap")
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
  let flow = Masc_tui_task_flow.of_tasks ~now tasks in
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

let test_assignee_rows_capped () =
  let now = Option.get (Masc_domain.parse_iso8601_opt "2026-09-12T00:00:00Z") in
  let task id created_at status = domain_task ~id ~created_at ~status in
  let tasks =
    List.init 13 (fun index ->
      let who = Printf.sprintf "holder-%02d" index in
      task (Printf.sprintf "t%02d" index) "2026-09-11T00:00:00Z"
        (Masc_domain.Claimed { assignee = who; claimed_at = "2026-09-11T01:00:00Z" }))
  in
  let flow = Masc_tui_task_flow.of_tasks ~now tasks in
  check int "every assignee is retained in the snapshot" 13 (List.length flow.by_assignee);
  let state = make_state () in
  state.task_flow <- Some flow;
  let output = String.concat "\n" (Render_metrics.render_section_resources ~cols:160 state) in
  check bool "the tail is reported rather than dropped" true
    (contains output "3 further assignees not listed")
;;

(* The ATTENTION card and the Memory & Gate Safety section both draw the gate
   observation, and the scheduler card names one condition twice. A state with
   two names is a state the reader has to match up by position. *)
let test_one_name_per_observation_state () =
  let state = make_state () in
  state.metrics_section <- Types.Section_tools;
  let lines = ref [] in
  let push line = lines := line :: !lines in
  Render_metrics.render_metrics_body ~cols:200 ~budget:60 state
    ~report_scroll:(fun _ -> ())
    ~push ~push_styled:(fun ~style:_ line -> push line)
    ~push_selected:push ~push_divider:(fun () -> ())
    ~push_empty:(fun () -> ());
  let output = String.concat "\n" (List.rev !lines) in
  check bool "the card names an unread gate" true
    (contains output "Gate not observed");
  check bool "and the section names it the same way" true
    (contains output "Pending Gate Calls: not observed");
  check bool "not under a second name" false (contains output "Gate unread");
  check bool "the scheduler card names one condition once" false
    (contains output "Probe unavailable")
;;

let test_overview_pulse_line () =
  let state = make_state () in
  let pulse = Render_metrics.overview_pulse_line ~cols:120 state in
  check bool "pulse line bounded to cols" true (Layout.display_width pulse <= 120);
  check bool "pulse line not empty" true (String.length pulse > 0);
  let pulse_narrow = Render_metrics.overview_pulse_line ~cols:30 state in
  check bool "narrow pulse line bounded" true (Layout.display_width pulse_narrow <= 30)
;;

(* The keeper files are read only once the server vouches for this workspace,
   and the roster is empty before that as well as after a read that found
   none. The pulse counts it only once it was read (#35747). *)
let test_pulse_roster_waits_for_the_local_read () =
  let state = make_state () in
  state.keepers <- [];
  let pulse () = Render_metrics.overview_pulse_line ~cols:160 state in
  check bool "an unread roster is unavailable" true
    (contains (pulse ()) "roster unavailable");
  check bool "and is not counted as none" false (contains (pulse ()) "0 configured");
  state.local_workspace <- Types.Local_workspace_read;
  state.keepers <- [ make_keeper "alpha"; make_keeper ~paused:true "beta" ];
  check bool "a read roster is counted" true
    (contains (pulse ()) "2 configured · 1 unpaused")
;;

let test_section_pills_line () =
  let line_fleet = Render_metrics.section_pills_line ~cols:100 ~active:Types.Section_fleet in
  check bool "fleet line bounded" true (Layout.display_width line_fleet <= 100);
  let line_res = Render_metrics.section_pills_line ~cols:100 ~active:Types.Section_resources in
  check bool "res line bounded" true (Layout.display_width line_res <= 100);
  let line_tools = Render_metrics.section_pills_line ~cols:100 ~active:Types.Section_tools in
  check bool "tools line bounded" true (Layout.display_width line_tools <= 100)
;;

let test_section_fleet_lines () =
  let state = make_state () in
  let lines = Render_metrics.render_section_fleet ~cols:90 state in
  check bool "fleet section produces lines" true (List.length lines > 0);
  List.iter
    (fun line ->
      check bool "fleet line bounded" true (Layout.display_width line <= 90))
    lines
;;

let test_section_resources_lines () =
  let state = make_state () in
  let lines = Render_metrics.render_section_resources ~cols:90 state in
  check bool "resources section produces lines" true (List.length lines > 0);
  List.iter
    (fun line ->
      check bool "resources line bounded" true (Layout.display_width line <= 90))
    lines
;;

let test_section_tools_lines () =
  let state = make_state () in
  let lines = Render_metrics.render_section_tools ~cols:90 state in
  check bool "tools section produces lines" true (List.length lines > 0);
  List.iter
    (fun line ->
      check bool "tools line bounded" true (Layout.display_width line <= 90))
    lines
;;

let test_narrow_and_wide_terminals () =
  let state = make_state () in
  let widths = [ 40; 55; 65; 80; 100; 120 ] in
  List.iter
    (fun cols ->
      let pulse = Render_metrics.overview_pulse_line ~cols state in
      check bool "pulse bounded" true (Layout.display_width pulse <= cols);
      let pills = Render_metrics.section_pills_line ~cols ~active:Types.Section_fleet in
      check bool "pills bounded" true (Layout.display_width pills <= cols);
      let fleet = Render_metrics.render_section_fleet ~cols state in
      List.iter (fun l -> check bool "fleet line bounded" true (Layout.display_width l <= cols)) fleet;
      let res = Render_metrics.render_section_resources ~cols state in
      List.iter (fun l -> check bool "res line bounded" true (Layout.display_width l <= cols)) res;
      let tools = Render_metrics.render_section_tools ~cols state in
      List.iter (fun l -> check bool "tools line bounded" true (Layout.display_width l <= cols)) tools)
    widths
;;

let test_section_fleet_populated () =
  let state = make_state () in
  let now = Unix.gettimeofday () in
  state.keeper_turn_finishes <-
    [ ("keeper-alpha", now -. 30.0)
    ; ("keeper-alpha", now -. 90.0)
    ; ("keeper-beta", now -. 300.0)
    ; ("keeper-beta", now -. 3600.0)
    ];
  let lines = Render_metrics.render_section_fleet ~cols:90 state in
  check bool "fleet section produces lines with activity" true (List.length lines > 0);
  let pulse = Render_metrics.overview_pulse_line ~cols:100 state in
  check bool "pulse non-empty" true (String.length pulse > 0)
;;

let test_section_resources_populated () =
  let state = make_state () in
  let kh1 = make_keeper_health ~keeper_id:"alpha" ~facts:25 ~snapshot_bytes:4096 in
  let kh2 = make_keeper_health ~keeper_id:"beta" ~facts:50 ~snapshot_bytes:8192 in
  let mhs = make_memory_health ~total_facts:75 ~source_facts:10 ~keepers:[ kh1; kh2 ] in
  state.memory_health <- Some mhs;
  let lines = Render_metrics.render_section_resources ~cols:90 state in
  check bool "resources populated produces lines" true (List.length lines > 0);
  List.iter (fun l -> check bool "resource line bounded" true (Layout.display_width l <= 90)) lines
;;

let test_section_tools_populated () =
  let state = make_state () in
  let gp = make_gate_pending ~id:"gp1" ~keeper:"alpha" in
  state.gate_pending <- [ gp ];
  state.gate_snapshot_observed <- true;
  let lines = Render_metrics.render_section_tools ~cols:90 state in
  check bool "tools populated produces lines" true (List.length lines > 0);
  List.iter (fun l -> check bool "tool line bounded" true (Layout.display_width l <= 90)) lines
;;

let test_approval_source_observations () =
  let state = make_state () in
  (* A successful read of the workspace cannot establish approval source data. *)
  state.local_workspace <- Types.Local_workspace_read;
  let kpis = Render_metrics.calculate_kpis state in
  check (option int) "unread Gate is not zero" None kpis.gate_pending_count;
  check (option int) "unread held calls are not zero" None kpis.held_approvals_count;
  let governance () = String.concat "\n" (Render_metrics.render_section_tools ~cols:120 state) in
  let output = governance () in
  check bool "first read stays explicit" true (contains output "Pending Gate Calls: not observed");
  check bool "unread queues cannot claim empty" false (contains output "no active pending");
  state.gate_snapshot_observed <- true;
  state.keeper_tool_approvals_observed <- true;
  let kpis = Render_metrics.calculate_kpis state in
  check (option int) "observed empty Gate is zero" (Some 0) kpis.gate_pending_count;
  check (option int) "observed empty held calls are zero" (Some 0) kpis.held_approvals_count;
  check bool "both observed queues may claim empty" true (contains (governance ()) "no active pending");
  state.gate_pending <- [ make_gate_pending ~id:"gp1" ~keeper:"alpha" ];
  state.gate_error <- Some "gate-refresh-offline";
  let kpis = Render_metrics.calculate_kpis state in
  check (option int) "stale Gate count is not current" None kpis.gate_pending_count;
  check (option int) "available held count survives" (Some 0) kpis.held_approvals_count;
  let output = governance () in
  check bool "stale source error is visible" true (contains output "gate-refresh-offline");
  check bool "stale tool is not charted" false (contains output "bash");
  check bool "partial empty cannot claim all empty" false (contains output "no active pending");
  state.gate_error <- None;
  state.gate_rules_unavailable <- Some "rules-store-offline";
  check (option int) "rules failure does not hide ready queue" (Some 1)
    (Render_metrics.calculate_kpis state).gate_pending_count;
  let output = governance () in
  check bool "partial store error is visible" true (contains output "Standing Rules: unavailable: rules-store-offline");
  check bool "available tool is charted" true (contains output "bash")
;;

let test_render_metrics_body_budget () =
  let state = make_state () in
  let count = ref 0 in
  Render_metrics.render_metrics_body
    ~cols:80
    ~budget:15
    state
    ~report_scroll:(fun _ -> ())
    ~push:(fun _ -> incr count)
    ~push_styled:(fun ~style:_ _ -> incr count)
    ~push_selected:(fun _ -> incr count)
    ~push_divider:(fun () -> incr count)
    ~push_empty:(fun () -> incr count);
  check bool "lines within budget" true (!count <= 15)
;;

(* The section's lines are formatted here, so the keypress cannot bound the
   scroll and steps an unbounded value. Before the frame reported back, the
   stored value kept climbing past the end and coming home took one press per
   step taken beyond it -- and End had nothing to correct the row it named.
   What the drawing could actually start at is what it hands back. *)
let test_metrics_reports_the_row_it_could_draw () =
  let render ~budget ~scroll =
    let state = make_state () in
    state.metrics_section <- Types.Section_fleet;
    state.metrics_scroll <- scroll;
    let reported = ref (-1) in
    let drawn = ref 0 in
    Render_metrics.render_metrics_body
      ~cols:85
      ~budget
      ~report_scroll:(fun s -> reported := s)
      state
      ~push:(fun _ -> incr drawn)
      ~push_styled:(fun ~style:_ _ -> incr drawn)
      ~push_selected:(fun _ -> incr drawn)
      ~push_divider:(fun () -> incr drawn)
      ~push_empty:(fun () -> incr drawn);
    !reported
  in
  let settled = render ~budget:20 ~scroll:max_int in
  check bool "a row past the end comes back as a row that exists" true
    (settled >= 0 && settled < max_int);
  check int "and asking for that row again is already there" settled
    (render ~budget:20 ~scroll:settled);
  check int "the top is the top" 0 (render ~budget:20 ~scroll:0);
  check int "and a negative scroll is the top too" 0
    (render ~budget:20 ~scroll:(-5));
  (* A budget with room for every line has no scroll to report. *)
  check int "nothing to scroll reports the top" 0
    (render ~budget:400 ~scroll:max_int)

let test_compact_metrics_preserve_source_labels () =
  List.iter (fun cols ->
    let state = make_state () in
    state.metrics_section <- Types.Section_fleet;
    let lines = ref [] in
    let push line = lines := line :: !lines in
    Render_metrics.render_metrics_body ~cols ~budget:40 state
      ~report_scroll:(fun _ -> ())
      ~push ~push_styled:(fun ~style:_ line -> push line)
      ~push_selected:push ~push_divider:(fun () -> ())
      ~push_empty:(fun () -> ());
    let output = String.concat "\n" !lines in
    check bool "task source availability remains readable" true
      (contains output "Task snapshot unavailable");
    check bool "scheduler observation remains readable" true
      (contains output "Lag not observed");
    List.iter (fun line ->
      check bool "summary stays inside viewport" true
        (Layout.display_width line <= cols)) !lines)
    [ 85; 100; 120; 150; 170 ]
;;

let test_render_metrics_body_all_sections () =
  let state = make_state () in
  let sections = [ Types.Section_fleet; Types.Section_resources; Types.Section_tools ] in
  List.iter
    (fun sec ->
      state.metrics_section <- sec;
      state.metrics_scroll <- 2;
      let count = ref 0 in
      Render_metrics.render_metrics_body
        ~cols:85
        ~budget:20
        ~report_scroll:(fun _ -> ())
        state
        ~push:(fun _ -> incr count)
        ~push_styled:(fun ~style:_ _ -> incr count)
        ~push_selected:(fun _ -> incr count)
        ~push_divider:(fun () -> incr count)
        ~push_empty:(fun () -> incr count);
      check bool "section rendered within budget" true (!count <= 20))
    sections
;;

let () =
  run "tui_render_metrics"
    [ ( "kpis"
      , [ test_case "calculate_kpis_empty" `Quick test_calculate_kpis_empty
        ; test_case "calculate_kpis_populated" `Quick test_calculate_kpis_populated
        ; test_case "retained task outcomes and observation scope" `Quick test_retained_task_outcomes
        ; test_case "assignee work and daily flow" `Quick test_assignee_work_and_daily_flow
        ; test_case "assignee rows capped" `Quick test_assignee_rows_capped
        ] )
    ; ( "overview_pulse"
      , [ test_case "overview_pulse_line" `Quick test_overview_pulse_line
        ; test_case "pulse roster waits for the local read" `Quick
            test_pulse_roster_waits_for_the_local_read
        ; test_case "one name per observation state" `Quick
            test_one_name_per_observation_state
        ] )
    ; ( "section_pills"
      , [ test_case "section_pills_line" `Quick test_section_pills_line ] )
    ; ( "sections"
      , [ test_case "fleet" `Quick test_section_fleet_lines
        ; test_case "scheduler sample availability" `Quick test_scheduler_sample_availability
        ; test_case "resources" `Quick test_section_resources_lines
        ; test_case "tools" `Quick test_section_tools_lines
        ; test_case "fleet_populated" `Quick test_section_fleet_populated
        ; test_case "resources_populated" `Quick test_section_resources_populated
        ; test_case "tools_populated" `Quick test_section_tools_populated
        ; test_case "approval source observations" `Quick test_approval_source_observations
        ] )
    ; ( "responsiveness"
      , [ test_case "narrow_and_wide" `Quick test_narrow_and_wide_terminals ] )
    ; ( "render_body"
      , [ test_case "budget" `Quick test_render_metrics_body_budget
        ; test_case "reports the row it could draw" `Quick
            test_metrics_reports_the_row_it_could_draw
        ; test_case "compact metrics preserve source labels" `Quick test_compact_metrics_preserve_source_labels
        ; test_case "all_sections" `Quick test_render_metrics_body_all_sections
        ] )
    ]
;;
