open Alcotest
module Types = Masc_tui_types
module Decode = Masc.Tui_decode
module Layout = Masc_tui_message_layout
module Render_metrics = Masc_tui_render_metrics

let make_state () =
  Types.create_state ~workspace:"" ~port:0 ~refresh_interval:0. ()
;;

let make_keeper ?(paused = false) name : Decode.keeper =
  { k_name = name
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
        ktr_state = Keeper_turn_running { lane = Turn_lane_autonomous; started_at_unix = 1.; preview = None } };
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

let test_overview_pulse_line () =
  let state = make_state () in
  let pulse = Render_metrics.overview_pulse_line ~cols:120 state in
  check bool "pulse line bounded to cols" true (Layout.display_width pulse <= 120);
  check bool "pulse line not empty" true (String.length pulse > 0);
  let pulse_narrow = Render_metrics.overview_pulse_line ~cols:30 state in
  check bool "narrow pulse line bounded" true (Layout.display_width pulse_narrow <= 30)
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
  let lines = Render_metrics.render_section_tools ~cols:90 state in
  check bool "tools populated produces lines" true (List.length lines > 0);
  List.iter (fun l -> check bool "tool line bounded" true (Layout.display_width l <= 90)) lines
;;

let test_render_metrics_body_budget () =
  let state = make_state () in
  let count = ref 0 in
  Render_metrics.render_metrics_body
    ~cols:80
    ~budget:15
    state
    ~push:(fun _ -> incr count)
    ~push_styled:(fun ~style:_ _ -> incr count)
    ~push_selected:(fun _ -> incr count)
    ~push_divider:(fun () -> incr count)
    ~push_empty:(fun () -> incr count);
  check bool "lines within budget" true (!count <= 15)
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
        ] )
    ; ( "overview_pulse"
      , [ test_case "overview_pulse_line" `Quick test_overview_pulse_line ] )
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
        ] )
    ; ( "responsiveness"
      , [ test_case "narrow_and_wide" `Quick test_narrow_and_wide_terminals ] )
    ; ( "render_body"
      , [ test_case "budget" `Quick test_render_metrics_body_budget
        ; test_case "all_sections" `Quick test_render_metrics_body_all_sections
        ] )
    ]
;;
