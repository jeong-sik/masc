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

let make_task ~id ~title ~status : Decode.task =
  { id
  ; title
  ; status
  ; priority = 1
  ; goal_ids = []
  }
;;

let make_keeper_health ~keeper_id ~facts ~snapshot_bytes : Decode.memory_keeper_health =
  { mkh_keeper_id = keeper_id
  ; mkh_revision = 1
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

let test_calculate_kpis_empty () =
  let state = make_state () in
  let kpis = Render_metrics.calculate_kpis state in
  check int "total keepers 0" 0 kpis.total_keepers;
  check int "active keepers 0" 0 kpis.active_keepers;
  check int "total tasks 0" 0 kpis.total_tasks;
  check int "done tasks 0" 0 kpis.done_tasks;
  check int "active tasks 0" 0 kpis.active_tasks;
  check int "awaiting tasks 0" 0 kpis.awaiting_tasks;
  check int "total facts 0" 0 kpis.total_facts;
  check int "ordinary facts 0" 0 kpis.ordinary_facts;
  check int "source facts 0" 0 kpis.source_facts;
  check int "snapshot bytes 0" 0 kpis.snapshot_bytes;
  check int "gate pending 0" 0 kpis.gate_pending_count;
  check int "held approvals 0" 0 kpis.held_approvals_count
;;

let test_calculate_kpis_populated () =
  let state = make_state () in
  let k1 = make_keeper ~paused:false "keeper-alpha" in
  let k2 = make_keeper ~paused:true "keeper-beta" in
  state.keepers <- [ k1; k2 ];
  let t1 = make_task ~id:"t1" ~title:"Task 1" ~status:(Masc_domain.Done { assignee = "keeper-alpha"; completed_at = "now"; notes = None }) in
  let t2 = make_task ~id:"t2" ~title:"Task 2" ~status:(Masc_domain.InProgress { assignee = "keeper-alpha"; started_at = "now" }) in
  let t3 = make_task ~id:"t3" ~title:"Task 3" ~status:(Masc_domain.AwaitingVerification { assignee = "keeper-alpha"; started_at = "now"; submitted_at = "now"; intent = Masc_domain.Complete_task; verification_id = "v1" }) in
  state.tasks <- [ t1; t2; t3 ];
  let kh1 = make_keeper_health ~keeper_id:"keeper-alpha" ~facts:20 ~snapshot_bytes:2048 in
  let mhs = make_memory_health ~total_facts:20 ~source_facts:5 ~keepers:[ kh1 ] in
  state.memory_health <- Some mhs;
  let gp = make_gate_pending ~id:"gp1" ~keeper:"keeper-alpha" in
  state.gate_pending <- [ gp ];
  let kpis = Render_metrics.calculate_kpis state in
  check int "total keepers 2" 2 kpis.total_keepers;
  check int "active keepers 1" 1 kpis.active_keepers;
  check int "total tasks 3" 3 kpis.total_tasks;
  check int "done tasks 1" 1 kpis.done_tasks;
  check int "active tasks 1" 1 kpis.active_tasks;
  check int "awaiting tasks 1" 1 kpis.awaiting_tasks;
  check int "total facts 20" 20 kpis.total_facts;
  check int "ordinary facts 15" 15 kpis.ordinary_facts;
  check int "source facts 5" 5 kpis.source_facts;
  check int "snapshot bytes 2048" 2048 kpis.snapshot_bytes;
  check int "gate pending count 1" 1 kpis.gate_pending_count
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
  check bool "tools line bounded" true (Layout.display_width line_tools <= 100);
  let line_latency = Render_metrics.section_pills_line ~cols:100 ~active:Types.Section_latency in
  check bool "latency line bounded" true (Layout.display_width line_latency <= 100)
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

let test_section_latency_lines () =
  let state = make_state () in
  let lines = Render_metrics.render_section_latency ~cols:90 state in
  check bool "latency section produces lines" true (List.length lines > 0);
  List.iter
    (fun line ->
      check bool "latency line bounded" true (Layout.display_width line <= 90))
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
      List.iter (fun l -> check bool "tools line bounded" true (Layout.display_width l <= cols)) tools;
      let lat = Render_metrics.render_section_latency ~cols state in
      List.iter (fun l -> check bool "lat line bounded" true (Layout.display_width l <= cols)) lat)
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
  let sections = [ Types.Section_fleet; Types.Section_resources; Types.Section_tools; Types.Section_latency ] in
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
        ] )
    ; ( "overview_pulse"
      , [ test_case "overview_pulse_line" `Quick test_overview_pulse_line ] )
    ; ( "section_pills"
      , [ test_case "section_pills_line" `Quick test_section_pills_line ] )
    ; ( "sections"
      , [ test_case "fleet" `Quick test_section_fleet_lines
        ; test_case "resources" `Quick test_section_resources_lines
        ; test_case "tools" `Quick test_section_tools_lines
        ; test_case "latency" `Quick test_section_latency_lines
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
