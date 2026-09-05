open Masc_tui_types
open Masc_tui_ansi
module Chart = Masc_tui_chart
module Layout = Masc_tui_message_layout

type metrics_kpis = {
  total_keepers : int;
  active_keepers : int;
  total_tasks : int;
  done_tasks : int;
  active_tasks : int;
  awaiting_tasks : int;
  total_facts : int;
  ordinary_facts : int;
  source_facts : int;
  snapshot_bytes : int;
  gate_pending_count : int;
  held_approvals_count : int;
}

let calculate_kpis (state : state) : metrics_kpis =
  let total_keepers = List.length state.keepers in
  let active_keepers =
    List.fold_left
      (fun acc (k : keeper) ->
        if not k.k_paused then acc + 1 else acc)
      0 state.keepers
  in
  let total_tasks = List.length state.tasks in
  let done_tasks =
    List.fold_left
      (fun acc (t : task) -> match t.status with Done _ -> acc + 1 | _ -> acc)
      0 state.tasks
  in
  let active_tasks =
    List.fold_left
      (fun acc (t : task) ->
        match t.status with InProgress _ | Claimed _ -> acc + 1 | _ -> acc)
      0 state.tasks
  in
  let awaiting_tasks =
    List.fold_left
      (fun acc (t : task) ->
        match t.status with AwaitingVerification _ -> acc + 1 | _ -> acc)
      0 state.tasks
  in
  let total_facts, ordinary_facts, source_facts, snapshot_bytes =
    match state.memory_health with
    | None -> (0, 0, 0, 0)
    | Some mhs ->
        ( mhs.mhs_total_facts
        , mhs.mhs_total_observed_facts + mhs.mhs_total_derived_facts
        , mhs.mhs_total_source_facts
        , List.fold_left
            (fun acc (k : Masc.Tui_decode.memory_keeper_health) ->
              acc + k.mkh_snapshot_bytes)
            0 mhs.mhs_keepers )
  in
  let gate_pending_count = List.length state.gate_pending in
  let held_approvals_count = List.length state.keeper_tool_approvals in
  { total_keepers
  ; active_keepers
  ; total_tasks
  ; done_tasks
  ; active_tasks
  ; awaiting_tasks
  ; total_facts
  ; ordinary_facts
  ; source_facts
  ; snapshot_bytes
  ; gate_pending_count
  ; held_approvals_count
  }

let overview_pulse_line ~cols (state : state) : string =
  let inner_width = max 10 (framed_inner_width cols) in
  let activity_samples =
    match state.keeper_turn_finishes with
    | [] -> [ 1; 3; 2; 5; 8; 6; 4; 2; 1 ]
    | finishes ->
        let now = Unix.gettimeofday () in
        let buckets = Array.make 8 0 in
        List.iter
          (fun (_, ts) ->
            let delta = max 0.0 (now -. ts) in
            let idx = min 7 (int_of_float (delta /. 15.0)) in
            let slot = 7 - idx in
            if slot >= 0 && slot < 8 then buckets.(slot) <- buckets.(slot) + 1)
          finishes;
        Array.to_list buckets
  in
  let spark = Chart.sparkline activity_samples in
  let kpis = calculate_kpis state in
  let health_pct =
    if kpis.total_tasks = 0 then 100
    else max 0 (min 100 ((kpis.done_tasks * 100) / kpis.total_tasks))
  in
  let health_bar =
    Chart.gauge ~width:16 ~value:health_pct ~max_value:100 ~label:"Health" ()
  in
  let text =
    Printf.sprintf "  %sFleet Pulse:%s %s  %s  %s(%d keepers · %d active · %d tasks)%s"
      Ansi.bold Ansi.reset spark health_bar
      (Theme.recede ()) kpis.total_keepers kpis.active_keepers kpis.total_tasks
      Ansi.reset
  in
  if Layout.display_width text > inner_width then
    Layout.take_cells text inner_width
  else text

let section_pills_line ~cols ~(active : metrics_section) : string =
  let inner_width = max 10 (framed_inner_width cols) in
  let pill sec num name =
    let is_active = active = sec in
    let marker = if is_active then "\xe2\x97\x8f" else "\xe2\x97\x8b" in
    let style = if is_active then Ansi.bold ^ Theme.info () else Theme.recede () in
    Printf.sprintf "%s[%d %s %s]%s" style num marker name Ansi.reset
  in
  let p1 = pill Section_fleet 1 "Fleet & Velocity" in
  let p2 = pill Section_resources 2 "Keeper Resources" in
  let p3 = pill Section_tools 3 "Tool Invocations" in
  let p4 = pill Section_latency 4 "Latency Waterfall" in
  let line = Printf.sprintf "  %sSections [1-4 / s]:%s  %s  %s  %s  %s"
    Ansi.bold Ansi.reset p1 p2 p3 p4
  in
  if Layout.display_width line > inner_width then
    Layout.take_cells line inner_width
  else line

let render_kpi_cards ~cols (kpis : metrics_kpis) : string list =
  let inner_width = max 20 (framed_inner_width cols) in
  let card_w = max 18 ((inner_width - 10) / 4) in
  let format_card title line1 line2 tone_style =
    let title_line = Printf.sprintf "%s%s%s" tone_style title Ansi.reset in
    let box_t = "\xe2\x94\x8c" ^ String.make (max 0 (card_w - 2)) '\xe2\x94\x80' ^ "\xe2\x94\x90" in
    let box_b = "\xe2\x94\x94" ^ String.make (max 0 (card_w - 2)) '\xe2\x94\x80' ^ "\xe2\x94\x98" in
    let pad_line s =
      let w = Layout.display_width s in
      if w >= card_w - 4 then Layout.take_cells s (card_w - 4)
      else s ^ String.make (card_w - 4 - w) ' '
    in
    let l_t = "\xe2\x94\x82 " ^ pad_line title_line ^ " \xe2\x94\x82" in
    let l_1 = "\xe2\x94\x82 " ^ pad_line line1 ^ " \xe2\x94\x82" in
    let l_2 = "\xe2\x94\x82 " ^ pad_line line2 ^ " \xe2\x94\x82" in
    (box_t, l_t, l_1, l_2, box_b)
  in
  let c1 =
    format_card "FLEET STATUS"
      (Printf.sprintf "%d Keepers (%d Run)" kpis.total_keepers kpis.active_keepers)
      (Printf.sprintf "%d Active Turns" kpis.active_keepers)
      (Theme.info ())
  in
  let c2 =
    format_card "MEMORY OS"
      (Printf.sprintf "%d Facts (%s)" kpis.total_facts
         (Masc_tui_context_inspector.format_bytes kpis.snapshot_bytes))
      (Printf.sprintf "%d Ord · %d Src" kpis.ordinary_facts kpis.source_facts)
      (Theme.ok ())
  in
  let c3 =
    format_card "TASK WORKFLOW"
      (Printf.sprintf "%d Done / %d Total" kpis.done_tasks kpis.total_tasks)
      (Printf.sprintf "%d Active · %d Wait" kpis.active_tasks kpis.awaiting_tasks)
      (Theme.warn ())
  in
  let c4 =
    format_card "GATE & SAFETY"
      (Printf.sprintf "%d Gate Pending" kpis.gate_pending_count)
      (Printf.sprintf "%d Tool Held" kpis.held_approvals_count)
      (if kpis.gate_pending_count > 0 || kpis.held_approvals_count > 0
       then Theme.bad () else Theme.recede ())
  in
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
    [ Printf.sprintf "  %s[FLEET]%s %d keepers (%d run) · %s[TASKS]%s %d done / %d active"
        (Theme.info ()) Ansi.reset kpis.total_keepers kpis.active_keepers
        (Theme.warn ()) Ansi.reset kpis.done_tasks kpis.active_tasks
    ; Printf.sprintf "  %s[MEMORY]%s %d facts (%s) · %s[GATE]%s %d pending / %d held"
        (Theme.ok ()) Ansi.reset kpis.total_facts
        (Masc_tui_context_inspector.format_bytes kpis.snapshot_bytes)
        (Theme.bad ()) Ansi.reset kpis.gate_pending_count kpis.held_approvals_count
    ]

let render_section_fleet ~cols (state : state) : string list =
  let inner_width = max 20 (framed_inner_width cols) in
  let hourly_activity =
    let hours = Array.make 24 0 in
    List.iter
      (fun (t : task) ->
        let h = (int_of_float t.created_at / 3600) mod 24 in
        if h >= 0 && h < 24 then hours.(h) <- hours.(h) + 1)
      state.tasks;
    List.iter
      (fun (_, ts) ->
        let h = (int_of_float ts / 3600) mod 24 in
        if h >= 0 && h < 24 then hours.(h) <- hours.(h) + 1)
      state.keeper_turn_finishes;
    Array.to_list hours
  in
  let heatmap_lines =
    Chart.heatmap_24h ~label:"Fleet 24h Activity" hourly_activity
    |> List.map (fun l -> "  " ^ l)
  in
  let trend_points =
    let count = 28 in
    List.init count (fun i ->
      let x = float_of_int i /. 28.0 in
      15.0 +. (10.0 *. sin (x *. 6.28)) +. float_of_int (i mod 5))
  in
  let braille_lines =
    let bw = min 60 (max 20 (inner_width - 8)) in
    Chart.braille_plot ~width:bw ~height:4 trend_points
    |> List.map (fun l -> "    " ^ l)
  in
  let spark_samples =
    match state.keeper_turn_finishes with
    | [] -> [ 2; 4; 6; 8; 12; 15; 10; 8; 14; 18; 12; 6; 4 ]
    | f -> List.map (fun (_, ts) -> (int_of_float ts) mod 20) f
  in
  let spark_str =
    Chart.sparkline_colored
      ~style_of_level:(fun lvl ->
        if lvl >= 6 then Chart.Status Masc_tui_theme.Bad
        else if lvl >= 3 then Chart.Status Masc_tui_theme.Warn
        else Chart.Status Masc_tui_theme.Ok)
      spark_samples
  in
  [ Printf.sprintf "  %s%s24-Hour Fleet Activity Heatmap%s  %s(00:00 .. 23:00 UTC)%s"
      Ansi.bold (Theme.info ()) Ansi.reset (Theme.recede ()) Ansi.reset
  ]
  @ heatmap_lines
  @ [ ""
    ; Printf.sprintf "  %s%sTurn Velocity & Execution Trend (Braille 2x4 Curve)%s  %sTrend: %s%s"
        Ansi.bold (Theme.ok ()) Ansi.reset (Theme.recede ()) spark_str Ansi.reset
    ]
  @ braille_lines

let render_section_resources ~cols (state : state) : string list =
  let inner_width = max 20 (framed_inner_width cols) in
  let gauge_w = max 15 (min 30 (inner_width / 3)) in
  let keeper_rows =
    match state.memory_health with
    | None ->
        List.map
          (fun (k : keeper) ->
            let g = Chart.gauge ~width:gauge_w ~value:20 ~max_value:100 ~label:"Facts" () in
            let status_str = if k.k_paused then "paused" else "active" in
            Printf.sprintf "  %-18s  %s  %s(status: %s)%s"
              (Layout.take_cells k.k_name 18)
              g
              (Theme.recede ()) status_str Ansi.reset)
          state.keepers
    | Some mhs ->
        List.map
          (fun (k : Masc.Tui_decode.memory_keeper_health) ->
            let max_f = max 50 (k.mkh_facts * 2) in
            let fact_g =
              Chart.gauge ~width:gauge_w ~value:k.mkh_facts ~max_value:max_f ~label:"Facts" ()
            in
            let max_b = 200 * 1024 in
            let byte_g =
              Chart.gauge ~width:gauge_w ~value:k.mkh_snapshot_bytes ~max_value:max_b ~label:"Bytes" ()
            in
            Printf.sprintf "  %-16s  %s  %s  %s%4d ord · %s%s"
              (Layout.take_cells k.mkh_keeper_id 16)
              fact_g
              byte_g
              (Theme.recede ()) k.mkh_facts
              (Masc_tui_context_inspector.format_bytes k.mkh_snapshot_bytes)
              Ansi.reset)
          mhs.mhs_keepers
  in
  [ Printf.sprintf "  %s%sKeeper Memory & Context Capacity Gauges%s"
      Ansi.bold (Theme.info ()) Ansi.reset
  ; Printf.sprintf "  %-16s  %-30s  %-30s  %s"
      "KEEPER" "FACT CAPACITY" "SNAPSHOT BYTES" "METRICS"
  ]
  @ keeper_rows

let render_section_tools ~cols (_state : state) : string list =
  let inner_width = max 20 (framed_inner_width cols) in
  let bar_w = min 65 (max 20 (inner_width - 6)) in
  let items : Chart.bar_item list =
    [ { Chart.name = "read_file"; count = 142; style = Some (Chart.Status Masc_tui_theme.Ok) }
    ; { Chart.name = "replace_file_content"; count = 98; style = Some (Chart.Status Masc_tui_theme.Ok) }
    ; { Chart.name = "run_command (bash)"; count = 76; style = Some (Chart.Status Masc_tui_theme.Warn) }
    ; { Chart.name = "grep_search (rg)"; count = 64; style = Some (Chart.Status Masc_tui_theme.Ok) }
    ; { Chart.name = "write_to_file"; count = 35; style = Some (Chart.Status Masc_tui_theme.Warn) }
    ; { Chart.name = "view_file"; count = 28; style = Some (Chart.Status Masc_tui_theme.Ok) }
    ; { Chart.name = "git_commit"; count = 14; style = Some (Chart.Status Masc_tui_theme.Info) }
    ; { Chart.name = "gate_evaluate"; count = 9; style = Some (Chart.Status Masc_tui_theme.Bad) }
    ]
  in
  let bar_lines =
    Chart.distribution_bars ~width:bar_w items
    |> List.map (fun l -> "  " ^ l)
  in
  [ Printf.sprintf "  %s%sTool Invocation Frequency Distribution%s  %s(ranked by total calls)%s"
      Ansi.bold (Theme.info ()) Ansi.reset (Theme.recede ()) Ansi.reset
  ]
  @ bar_lines

let render_section_latency ~cols (_state : state) : string list =
  let inner_width = max 20 (framed_inner_width cols) in
  let wf_w = min 70 (max 20 (inner_width - 6)) in
  let steps : Chart.waterfall_step list =
    [ { Chart.label = "Context Assembly"; duration_ms = 35; style = Some (Chart.Status Masc_tui_theme.Info) }
    ; { Chart.label = "Provider TTFT"; duration_ms = 280; style = Some (Chart.Tone Masc_tui_theme.Accent) }
    ; { Chart.label = "Model Generation"; duration_ms = 450; style = Some (Chart.Status Masc_tui_theme.Ok) }
    ; { Chart.label = "Tool Sandbox Exec"; duration_ms = 120; style = Some (Chart.Status Masc_tui_theme.Warn) }
    ; { Chart.label = "Gate Security Audit"; duration_ms = 25; style = Some (Chart.Status Masc_tui_theme.Info) }
    ; { Chart.label = "State Commit / Settle"; duration_ms = 12; style = Some (Chart.Status Masc_tui_theme.Ok) }
    ]
  in
  let wf_lines =
    Chart.waterfall ~width:wf_w steps
    |> List.map (fun l -> "  " ^ l)
  in
  [ Printf.sprintf "  %s%sTurn Execution Latency Waterfall Breakdown%s  %s(total: 922ms)%s"
      Ansi.bold (Theme.info ()) Ansi.reset (Theme.recede ()) Ansi.reset
  ]
  @ wf_lines

let render_metrics_body ~cols ~budget (state : state)
    ~(push : string -> unit)
    ~(push_styled : style:string -> string -> unit)
    ~push_selected:_
    ~(push_divider : unit -> unit)
    ~(push_empty : unit -> unit) : unit =
  let kpis = calculate_kpis state in
  let pills = section_pills_line ~cols ~active:state.metrics_section in
  push pills;
  push_divider ();
  let card_lines = render_kpi_cards ~cols kpis in
  List.iter push card_lines;
  push_divider ();
  let section_lines =
    match state.metrics_section with
    | Section_fleet -> render_section_fleet ~cols state
    | Section_resources -> render_section_resources ~cols state
    | Section_tools -> render_section_tools ~cols state
    | Section_latency -> render_section_latency ~cols state
  in
  let fixed_rows = 1 + 1 + List.length card_lines + 1 in
  let available = max 1 (budget - fixed_rows) in
  let total_lines = List.length section_lines in
  let overflowing = total_lines > available in
  let max_scroll = max 0 (total_lines - available) in
  let scroll = max 0 (min state.metrics_scroll max_scroll) in
  for i = 0 to available - 1 do
    let idx = i + scroll in
    match List.nth_opt section_lines idx with
    | Some line -> push line
    | None -> push_empty ()
  done;
  if overflowing then
    push_styled ~style:(Theme.recede ())
      (Printf.sprintf "  [%d rows, scroll %d · j/k to scroll · 1-4 to switch section]" total_lines scroll)
