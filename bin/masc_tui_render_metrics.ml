open Masc_tui_types
open Masc_tui_ansi
module Decode = Masc.Tui_decode
module Chart = Masc_tui_chart
module Layout = Masc_tui_message_layout

module Task_flow = Masc_tui_task_flow

type turn_counts = { running : int; idle : int; unavailable : int }
type metrics_kpis = {
  total_keepers : int;
  unpaused_keepers : int;
  turns : turn_counts option;
  tasks : Task_flow.counts option;
  gate_pending_count : int;
  held_approvals_count : int;
}

let calculate_kpis (state : state) =
  let turns =
    match state.keeper_turns_observed_at, state.keeper_turns_error with
    | Some _, None ->
      Some (List.fold_left
        (fun count (row : Decode.keeper_turn_row) ->
          match row.ktr_state with
          | Decode.Keeper_turn_running _ -> { count with running = count.running + 1 }
          | Keeper_turn_idle -> { count with idle = count.idle + 1 }
          | Keeper_turn_unavailable _ -> { count with unavailable = count.unavailable + 1 })
        { running = 0; idle = 0; unavailable = 0 } state.keeper_turns)
    | None, _ | _, Some _ -> None
  in
  { total_keepers = List.length state.keepers;
    unpaused_keepers = List.fold_left
      (fun count (keeper : keeper) -> count + (if keeper.k_paused then 0 else 1))
      0 state.keepers;
    turns;
    tasks = Option.map (fun flow -> flow.Task_flow.current) state.task_flow;
    gate_pending_count = List.length state.gate_pending;
    held_approvals_count = List.length state.keeper_tool_approvals }

let format_words words =
  Masc_tui_context_inspector.format_bytes (max 0 words * 8)

let format_megawords words =
  let mw = Float.abs words /. 1_000_000.0 in
  if mw >= 1000.0 then Printf.sprintf "%.1f GW" (mw /. 1000.0)
  else if mw >= 1.0 then Printf.sprintf "%.1f MW" mw
  else Printf.sprintf "%.0f kW" (words /. 1000.0)

let repeat_glyph glyph count =
  if count <= 0 then "" else String.concat "" (List.init count (fun _ -> glyph))

let scheduler_probe_text probe =
  match String.trim probe with "" -> "unreported" | value -> value

let pulse_line ~cols (state : state) kpis =
  let inner_width = max 10 (framed_inner_width cols) in
  let turns = match kpis.turns with
    | None -> "Turn observation unavailable"
    | Some count -> Printf.sprintf "Turns: %d running · %d idle · %d unavailable"
        count.running count.idle count.unavailable
  in
  let roster =
    if state.last_refresh = 0. || Option.is_some state.keepers_error then "roster unavailable"
    else Printf.sprintf "%d configured · %d unpaused" kpis.total_keepers kpis.unpaused_keepers
  in
  let text = Printf.sprintf "  %s%s%s  %s| %s%s"
      Ansi.bold turns Ansi.reset (Theme.recede ()) roster Ansi.reset in
  Layout.take_cells text inner_width ^ Ansi.reset

let overview_pulse_line ~cols state = pulse_line ~cols state (calculate_kpis state)

let section_pills_line ~cols ~(active : metrics_section) : string =
  let inner_width = max 10 (framed_inner_width cols) in
  let pill sec num name =
    let is_active = active = sec in
    let marker = if is_active then "\xe2\x97\x8f" else "\xe2\x97\x8b" in
    let style = if is_active then Ansi.bold ^ Theme.info () else Theme.recede () in
    Printf.sprintf "%s[%d %s %s]%s" style num marker name Ansi.reset
  in
  let p1 = pill Section_fleet 1 "Engine & Scheduler" in
  let p2 = pill Section_resources 2 "Work & Outcomes" in
  let p3 = pill Section_tools 3 "Memory & Gate Safety" in
  let line = Printf.sprintf "  %sSections [1-3 / s]:%s  %s  %s  %s"
    Ansi.bold Ansi.reset p1 p2 p3
  in
  if Layout.display_width line > inner_width then
    Layout.take_cells line inner_width ^ Ansi.reset
  else line

let render_kpi_cards ~cols (state : state) (kpis : metrics_kpis) : string list =
  let inner_width = max 20 (framed_inner_width cols) in
  let card_w = max 18 ((inner_width - 10) / 4) in
  let format_card title line1 line2 tone_style =
    let h_rule = repeat_glyph "\xe2\x94\x80" (max 0 (card_w - 2)) in
    let box_t = "\xe2\x94\x8c" ^ h_rule ^ "\xe2\x94\x90" in
    let box_b = "\xe2\x94\x94" ^ h_rule ^ "\xe2\x94\x98" in
    let pad_line s =
      let w = Layout.display_width s in
      if w >= card_w - 4 then Layout.take_cells s (card_w - 4)
      else s ^ String.make (card_w - 4 - w) ' '
    in
    let l_t = "\xe2\x94\x82 " ^ tone_style ^ pad_line title ^ Ansi.reset ^ " \xe2\x94\x82" in
    let l_1 = "\xe2\x94\x82 " ^ pad_line line1 ^ " \xe2\x94\x82" in
    let l_2 = "\xe2\x94\x82 " ^ pad_line line2 ^ " \xe2\x94\x82" in
    (box_t, l_t, l_1, l_2, box_b)
  in
  let gc_opt =
    match state.server_identity with
    | Some { sid_gc = Some gc; _ } -> Some gc
    | _ -> None
  in
  let sched_opt =
    match state.server_identity with
    | Some { sid_scheduler = Some s; _ } -> Some s
    | _ -> None
  in
  let domains = match sched_opt with
    | Some { ssch_pool_domains = Some count; _ } -> string_of_int count
    | _ -> "?"
  in
  let c1_l1, c1_l2 = match gc_opt with
    | Some gc ->
      (Printf.sprintf "Heap %s / live %s"
         (format_words gc.sgc_heap_words) (format_words gc.sgc_live_words),
       Printf.sprintf "%s workers · minor %s" domains (format_words gc.sgc_minor_heap_size))
    | None -> "GC not observed", "Workers " ^ domains
  in
  let c1 = format_card "ENGINE" c1_l1 c1_l2 (Theme.info ()) in
  let c2_l1, c2_l2, c2_tone = match sched_opt with
    | Some s when s.ssch_samples <= 0 ->
      "No latency samples", "Probe: " ^ scheduler_probe_text s.ssch_probe, Theme.recede ()
    | Some s ->
      (Printf.sprintf "p95 %.3fms · max %.3fms" s.ssch_p95_ms s.ssch_max_ms,
       Printf.sprintf "%d samples · %d stalls" s.ssch_samples s.ssch_stalls,
       if s.ssch_stalls > 0 then Theme.warn () else Theme.recede ())
    | None -> "Lag not observed", "Probe unavailable", Theme.recede ()
  in
  let c2 = format_card "SCHEDULER LAG" c2_l1 c2_l2 c2_tone in
  let c3_l1, c3_l2 = match kpis.tasks with
    | Some count ->
      (Printf.sprintf "%d open · %d verifying" (Task_flow.open_count count) count.awaiting_verification,
       Printf.sprintf "%d done · %d cancelled" count.completed count.cancelled)
    | None -> "Task snapshot unavailable", "No outcome count inferred"
  in
  let c3 = format_card "TASK SNAPSHOT" c3_l1 c3_l2 (Theme.info ()) in
  let c4_l1 = Printf.sprintf "%d Gate · %d tool holds"
      kpis.gate_pending_count kpis.held_approvals_count in
  let c4_l2 = "Visible approval queues" in
  let c4_tone = if kpis.gate_pending_count + kpis.held_approvals_count > 0
      then Theme.warn () else Theme.recede () in
  let c4 = format_card "ATTENTION" c4_l1 c4_l2 c4_tone in

  let combine (t1, lt1, l11, l21, b1)
              (t2, lt2, l12, l22, b2)
              (t3, lt3, l13, l23, b3)
              (t4, lt4, l14, l24, b4) =
    [ "  " ^ t1 ^ "  " ^ t2 ^ "  " ^ t3 ^ "  " ^ t4
    ; "  " ^ lt1 ^ "  " ^ lt2 ^ "  " ^ lt3 ^ "  " ^ lt4
    ; "  " ^ l11 ^ "  " ^ l12 ^ "  " ^ l13 ^ "  " ^ l14
    ; "  " ^ l21 ^ "  " ^ l22 ^ "  " ^ l23 ^ "  " ^ l24
    ; "  " ^ b1 ^ "  " ^ b2 ^ "  " ^ b3 ^ "  " ^ b4
    ]
  in
  if inner_width >= 80 then
    combine c1 c2 c3 c4
  else
    [ Printf.sprintf "  %s[ENGINE]%s %s · %s[SCHED]%s %s"
        (Theme.info ()) Ansi.reset c1_l1
        c2_tone Ansi.reset c2_l1
    ; Printf.sprintf "  %s[TASKS]%s %s · %s[HOLDS]%s %s"
        (Theme.info ()) Ansi.reset c3_l1
        c4_tone Ansi.reset c4_l1
    ]
    |> List.map (fun line -> if Layout.display_width line > inner_width then Layout.take_cells line inner_width ^ Ansi.reset else line)

let render_section_fleet ~cols (state : state) =
  let inner_width = max 20 (framed_inner_width cols) in
  let clip text = Layout.take_cells text inner_width ^ Ansi.reset in
  let title text = "  " ^ Ansi.bold ^ Theme.info () ^ text ^ Ansi.reset in
  let gc = Option.bind state.server_identity (fun identity -> identity.Decode.sid_gc) in
  let scheduler = Option.bind state.server_identity (fun identity -> identity.Decode.sid_scheduler) in
  let gc_lines = match gc with
    | None -> [ "    GC telemetry not observed" ]
    | Some gc ->
      [ Printf.sprintf "    Heap %s · live %s · configured minor heap %s"
          (format_words gc.sgc_heap_words) (format_words gc.sgc_live_words)
          (format_words gc.sgc_minor_heap_size)
      ; Printf.sprintf "    Collections: minor %d · major %d · forced %d · compactions %d"
          gc.sgc_minor_collections gc.sgc_major_collections
          gc.sgc_forced_major_collections gc.sgc_compactions
      ; Printf.sprintf "    Allocation totals: minor %s · promoted %s · major %s"
          (format_megawords gc.sgc_minor_words) (format_megawords gc.sgc_promoted_words)
          (format_megawords gc.sgc_major_words) ]
  in
  let scheduler_lines = match scheduler with
    | None -> [ "    Scheduler telemetry not observed" ]
    | Some sched when sched.ssch_samples <= 0 ->
      [ "    No latency samples in the producer window"
      ; Printf.sprintf "    Probe %s · worker domains %s"
          (scheduler_probe_text sched.ssch_probe)
          (Option.fold ~none:"unreported" ~some:string_of_int sched.ssch_pool_domains) ]
    | Some sched ->
      [ Printf.sprintf "    p50 %.3f ms · p95 %.3f ms · p99 %.3f ms"
          sched.ssch_p50_ms sched.ssch_p95_ms sched.ssch_p99_ms
      ; Printf.sprintf "    Maximum %.3f ms · mean %.3f ms · %d samples"
          sched.ssch_max_ms sched.ssch_mean_ms sched.ssch_samples
      ; Printf.sprintf "    Producer-reported stalls %d · probe %s · worker domains %s"
          sched.ssch_stalls
          (scheduler_probe_text sched.ssch_probe)
          (Option.fold ~none:"unreported" ~some:string_of_int sched.ssch_pool_domains)
      ; "    Scheduler delay measures runtime responsiveness, not task output." ]
  in
  let transport_lines = match state.transport with
    | None -> [ "    Transport telemetry not observed" ]
    | Some transport ->
      [ Printf.sprintf "    SSE sessions %d · WebSocket sessions %s · dropped events %d"
          transport.th_sse_sessions
          (Option.fold ~none:"unreported" ~some:string_of_int transport.th_websocket_sessions)
          transport.th_events_dropped
      ; "    Queue pressure: " ^ Masc.Transport_metrics.queue_pressure_kind_to_string transport.th_queue_pressure ]
  in
  List.map clip
    ([ title "Engine memory" ] @ gc_lines
     @ [ ""; title "Scheduler lag (producer sample window)" ] @ scheduler_lines
     @ [ ""; title "Transport delivery" ] @ transport_lines)

let timestamp_utc at =
  let tm = Unix.gmtime at in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d UTC"
    (tm.Unix.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min

let age_text seconds =
  let seconds = max 0. seconds in
  if seconds >= 86400. then Printf.sprintf "%.1fd" (seconds /. 86400.)
  else if seconds >= 3600. then Printf.sprintf "%.1fh" (seconds /. 3600.)
  else if seconds >= 60. then Printf.sprintf "%.1fm" (seconds /. 60.)
  else Printf.sprintf "%.1fs" seconds

let render_section_resources ~cols (state : state) =
  let inner_width = max 20 (framed_inner_width cols) in
  let clip text = Layout.take_cells text inner_width ^ Ansi.reset in
  let title text = "  " ^ Ansi.bold ^ Theme.info () ^ text ^ Ansi.reset in
  let now = Unix.gettimeofday () in
  let task_lines = match state.task_flow with
    | None ->
      [ "    Task snapshot unavailable"
      ; "    " ^ Option.value ~default:"Backlog has not been observed yet." state.tasks_error ]
    | Some flow ->
      let current = flow.Task_flow.current in
      [ Printf.sprintf "    New tasks %d · Done %d · Cancelled %d"
          flow.recent.created flow.recent.completed flow.recent.cancelled
      ; Printf.sprintf "    Window: %s — %s"
          (timestamp_utc flow.window_started_at) (timestamp_utc flow.observed_at)
      ; Printf.sprintf "    Current open %d: todo %d · claimed %d · working %d · verification %d"
          (Task_flow.open_count current) current.todo current.claimed current.in_progress
          current.awaiting_verification
      ; Printf.sprintf "    Retained total %d · Done %d · Cancelled %d · snapshot %s ago"
          (Task_flow.total_count current) current.completed current.cancelled
          (age_text (now -. flow.observed_at))
      ; "    Oldest open task registration: "
          ^ Option.fold ~none:"none with a known timestamp"
              ~some:(fun at -> age_text (flow.observed_at -. at) ^ " before this snapshot")
              flow.oldest_open_created_at
      ; "    Done is a task outcome; tool calls and turn endings are activity." ]
      @ (if flow.unparseable_timestamps = 0 then [] else
           [ Printf.sprintf "    %d invalid timestamps excluded from time-window counts"
               flow.unparseable_timestamps ])
      @ (match state.tasks_error with None -> [] | Some error ->
           [ "    Snapshot warning: " ^ error ])
  in
  let turn_lines = match state.keeper_turns_observed_at, state.keeper_turns_error with
    | _, Some error ->
      [ "    Current turn observation failed: " ^ error
      ; "    Previous rows are not counted as current running turns." ]
    | None, None -> [ "    Current turns have not been observed yet." ]
    | Some observed_at, None ->
      let running = List.filter_map
          (fun (row : Decode.keeper_turn_row) -> match row.ktr_state with
            | Keeper_turn_running { lane; started_at_unix; _ } ->
              Some (row.ktr_keeper_name, lane, started_at_unix)
            | Keeper_turn_idle | Keeper_turn_unavailable _ -> None)
          state.keeper_turns in
      let idle, unavailable = List.fold_left
          (fun (idle, unavailable) (row : Decode.keeper_turn_row) -> match row.ktr_state with
            | Keeper_turn_idle -> idle + 1, unavailable
            | Keeper_turn_unavailable _ -> idle, unavailable + 1
            | Keeper_turn_running _ -> idle, unavailable)
          (0, 0) state.keeper_turns in
      [ Printf.sprintf "    %d running · %d idle · %d unavailable · observed %s ago"
          (List.length running) idle unavailable (age_text (now -. observed_at))
      ; "    Turn age = since owner-reported start. Recent pane evt = since event receipt." ]
      @ List.map
          (fun (name, lane, started_at_unix) ->
              let lane = match lane with
                | Decode.Turn_lane_autonomous -> "autonomous"
                | Decode.Turn_lane_chat_operation -> "chat"
                | Decode.Turn_lane_maintenance -> "maintenance" in
              Printf.sprintf "    %-18s  turn %8s  lane %s"
                (Layout.fit_width name 18)
                (age_text (now -. started_at_unix)) lane)
          running
  in
  let safety_lines = match state.fleet_safety with
    | None -> [ "    Execution readiness not observed" ]
    | Some safety ->
      [ Printf.sprintf "    Executable %d / target %d · shortfall %d · failing %d · paused %d"
          safety.fs_executable_count safety.fs_target_reaction_capacity
          safety.fs_reaction_capacity_shortfall safety.fs_failing_count safety.fs_paused_count ]
  in
  List.map clip
    ([ title "Retained task outcomes · 24-hour snapshot window" ] @ task_lines
     @ [ ""; title "Current owner turns" ] @ turn_lines
     @ [ ""; title "Execution readiness (health snapshot)" ] @ safety_lines)

let render_section_tools ~cols (state : state) : string list =
  (* Section 3: Memory & Gate Safety *)
  let inner_width = max 20 (framed_inner_width cols) in
  let clip line =
    if Layout.display_width line > inner_width then
      Layout.take_cells line inner_width ^ Ansi.reset
    else line
  in
  let bar_w = min 60 (max 20 (inner_width - 8)) in

  let title_mem =
    Printf.sprintf "  %s%sMemory OS Knowledge Base & Fact Store%s"
      Ansi.bold (Theme.info ()) Ansi.reset
  in
  let mem_lines =
    match state.memory_health with
    | None ->
        [ "    (memory telemetry not loaded — visit Memory surface to fetch)" ]
    | Some mhs ->
        let total_facts = mhs.mhs_total_facts in
        let header =
          Printf.sprintf "    Ordinary facts: %d · source facts: %d · ordinary snapshots: %s"
            total_facts
            mhs.mhs_total_source_facts
            (Masc_tui_context_inspector.format_bytes (List.fold_left (fun acc (k : Decode.memory_keeper_health) -> acc + k.mkh_snapshot_bytes) 0 mhs.mhs_keepers))
        in
        let rows =
          if mhs.mhs_keepers = [] then
            [ "    (no registered keepers with memory partitions)" ]
          else
            List.map
              (fun (k : Decode.memory_keeper_health) ->
                let pct = if total_facts = 0 then 0 else (k.mkh_facts * 100) / total_facts in
                let bar = Chart.gauge ~width:16 ~value:pct ~max_value:100 ~label:"" () in
                Printf.sprintf "    %-16s  %4d facts  %s  %s%s"
                  (Layout.fit_width k.mkh_keeper_id 16)
                  k.mkh_facts
                  bar
                  (Masc_tui_context_inspector.format_bytes k.mkh_snapshot_bytes)
                  Ansi.reset)
              mhs.mhs_keepers
        in
        header :: rows
  in

  let title_gate =
    Printf.sprintf "  %s%sGate Governance & Security Stance%s"
      Ansi.bold (Theme.bad ()) Ansi.reset
  in
  let counts = Hashtbl.create 16 in
  List.iter
    (fun (gp : Decode.gate_pending) ->
      let tool = gp.gp_display_tool in
      let current = Option.value (Hashtbl.find_opt counts tool) ~default:0 in
      Hashtbl.replace counts tool (current + 1))
    state.gate_pending;
  List.iter
    (fun (kta : Decode.keeper_tool_approval) ->
      let tool = kta.kta_tool in
      let current = Option.value (Hashtbl.find_opt counts tool) ~default:0 in
      Hashtbl.replace counts tool (current + 1))
    state.keeper_tool_approvals;

  let yolo_count = List.length state.keeper_yolo_names in
  let rules_count = List.length state.gate_rules in
  let pending_count = List.length state.gate_pending in
  let held_count = List.length state.keeper_tool_approvals in

  let gate_summary =
    Printf.sprintf "    %sPending Gate Calls:%s %d   %sHeld Tool Approvals:%s %d   %sYOLO Keepers:%s %d   %sStanding Rules:%s %d"
      Ansi.bold Ansi.reset pending_count
      Ansi.bold Ansi.reset held_count
      Ansi.bold Ansi.reset yolo_count
      Ansi.bold Ansi.reset rules_count
  in
  let yolo_line =
    if state.keeper_yolo_names = [] then
      "    YOLO enabled: no keepers in the current snapshot"
    else
      "    YOLO Execution: " ^ String.concat ", " state.keeper_yolo_names
  in

  let tool_bars =
    if Hashtbl.length counts = 0 then
      [ "    (no active pending gate operations or held approval requests)" ]
    else
      let items =
        Hashtbl.fold
          (fun name count acc ->
            { Chart.name; count; style = Some (Chart.Status Masc_tui_theme.Warn) } :: acc)
          counts []
        |> List.sort (fun (a : Chart.bar_item) (b : Chart.bar_item) ->
               Int.compare b.count a.count)
      in
      Chart.distribution_bars ~width:bar_w items
      |> List.map (fun l -> "    " ^ l)
  in

  [ clip title_mem ]
  @ List.map clip mem_lines
  @ [ ""
    ; clip title_gate
    ; clip gate_summary
    ; clip yolo_line
    ; ""
    ]
  @ List.map clip tool_bars

let render_metrics_body ~cols ~budget (state : state)
    ~(push : string -> unit)
    ~(push_styled : style:string -> string -> unit)
    ~push_selected:_
    ~(push_divider : unit -> unit)
    ~(push_empty : unit -> unit) : unit =
  let kpis = calculate_kpis state in
  let pulse = pulse_line ~cols state kpis in
  push pulse;
  let pills = section_pills_line ~cols ~active:state.metrics_section in
  push pills;
  push_divider ();
  let card_lines = render_kpi_cards ~cols state kpis in
  List.iter push card_lines;
  push_divider ();
  let section_lines =
    match state.metrics_section with
    | Section_fleet -> render_section_fleet ~cols state
    | Section_resources -> render_section_resources ~cols state
    | Section_tools -> render_section_tools ~cols state
  in
  let fixed_rows = 1 + 1 + 1 + List.length card_lines + 1 in
  let room = max 0 (budget - fixed_rows) in
  let total_lines = List.length section_lines in
  let overflowing = total_lines > room in
  let hint_rows = if overflowing && room >= 2 then 1 else 0 in
  let available = max 0 (room - hint_rows) in
  let max_scroll = max 0 (total_lines - available) in
  let scroll = max 0 (min state.metrics_scroll max_scroll) in
  for i = 0 to available - 1 do
    let idx = i + scroll in
    match List.nth_opt section_lines idx with
    | Some line -> push line
    | None -> push_empty ()
  done;
  if hint_rows > 0 then
    let inner_width = max 20 (framed_inner_width cols) in
    let hint_text =
      Printf.sprintf "  [%d rows, scroll %d · j/k to scroll · 1-3 to switch section · Esc:overview]" total_lines scroll
    in
    let clipped =
      if Layout.display_width hint_text > inner_width then
        Layout.take_cells hint_text inner_width
      else hint_text
    in
    push_styled ~style:(Theme.recede ()) clipped
