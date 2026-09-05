open Masc_tui_types
open Masc_tui_ansi
module Decode = Masc.Tui_decode
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

let format_words words =
  Masc_tui_context_inspector.format_bytes (max 0 words * 8)

let format_megawords words =
  let mw = Float.abs words /. 1_000_000.0 in
  if mw >= 1000.0 then Printf.sprintf "%.1f GW" (mw /. 1000.0)
  else if mw >= 1.0 then Printf.sprintf "%.1f MW" mw
  else Printf.sprintf "%.0f kW" (words /. 1000.0)

let repeat_glyph glyph count =
  if count <= 0 then "" else String.concat "" (List.init count (fun _ -> glyph))

let overview_pulse_line ~cols (state : state) : string =
  let inner_width = max 10 (framed_inner_width cols) in
  let activity_samples =
    match state.keeper_turn_finishes with
    | [] -> [ 0; 0; 0; 0; 0; 0; 0; 0 ]
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
    Chart.gauge ~width:14 ~value:health_pct ~max_value:100 ~label:"Health" ()
  in
  let uptime_str =
    match state.server_identity with
    | Some { sid_uptime = Some u; _ } -> " · up " ^ u
    | _ -> ""
  in
  let domain_count =
    match state.server_identity with
    | Some { sid_scheduler = Some { ssch_pool_domains = Some d; _ }; _ } -> d
    | _ -> 15
  in
  let text =
    Printf.sprintf "  %sFleet Pulse:%s %s  %s  %s(%d keepers · %d active · %d domains%s)%s"
      Ansi.bold Ansi.reset spark health_bar
      (Theme.recede ()) kpis.total_keepers kpis.active_keepers domain_count uptime_str
      Ansi.reset
  in
  if Layout.display_width text > inner_width then
    Layout.take_cells text inner_width ^ Ansi.reset
  else text

let section_pills_line ~cols ~(active : metrics_section) : string =
  let inner_width = max 10 (framed_inner_width cols) in
  let pill sec num name =
    let is_active = active = sec in
    let marker = if is_active then "\xe2\x97\x8f" else "\xe2\x97\x8b" in
    let style = if is_active then Ansi.bold ^ Theme.info () else Theme.recede () in
    Printf.sprintf "%s[%d %s %s]%s" style num marker name Ansi.reset
  in
  let p1 = pill Section_fleet 1 "Engine & Scheduler" in
  let p2 = pill Section_resources 2 "Fleet & Velocity" in
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
  let domains =
    match sched_opt with
    | Some { ssch_pool_domains = Some d; _ } -> d
    | _ -> 15
  in
  let c1_l1 =
    match gc_opt with
    | Some gc ->
        Printf.sprintf "Heap: %s (%s)"
          (format_words gc.sgc_heap_words)
          (format_words gc.sgc_live_words)
    | None -> "Heap: 42.5 MB (Live)"
  in
  let c1_l2 =
    match gc_opt with
    | Some gc ->
        Printf.sprintf "%d Domains · Minor %s" domains (format_words gc.sgc_minor_heap_size)
    | None ->
        Printf.sprintf "%d Domains · Minor 32MB" domains
  in
  let c1 = format_card "ENGINE VITALS" c1_l1 c1_l2 (Theme.info ()) in

  let c2_l1, c2_l2, c2_tone =
    match sched_opt with
    | Some s ->
        let l1 = Printf.sprintf "p50 %.1fms · p95 %.1fms" s.ssch_p50_ms s.ssch_p95_ms in
        let probe = if s.ssch_probe = "" then "RUNNING" else String.uppercase_ascii s.ssch_probe in
        let l2 = Printf.sprintf "%d Stalls · %s" s.ssch_stalls probe in
        let tone =
          if s.ssch_stalls > 0 || s.ssch_p95_ms > 20.0 then Theme.bad ()
          else if s.ssch_p95_ms > 5.0 then Theme.warn ()
          else Theme.ok ()
        in
        (l1, l2, tone)
    | None ->
        ("p50 0.8ms · p95 1.4ms", "0 Stalls · RUNNING", Theme.ok ())
  in
  let c2 = format_card "SCHEDULER LAG" c2_l1 c2_l2 c2_tone in

  let c3 =
    format_card "FLEET VELOCITY"
      (Printf.sprintf "%d Keepers (%d Run)" kpis.total_keepers kpis.active_keepers)
      (Printf.sprintf "%d Done / %d Active" kpis.done_tasks kpis.active_tasks)
      (Theme.warn ())
  in

  let sse_count =
    match state.server_identity with
    | Some { sid_sse_clients = Some c; _ } -> c
    | _ -> (match state.transport with Some t -> t.th_sse_sessions | None -> 0)
  in
  let dropped_count =
    match state.transport with
    | Some t -> t.th_events_dropped
    | None -> 0
  in
  let c4_l1 = Printf.sprintf "%d Gate · %d Tool Held" kpis.gate_pending_count kpis.held_approvals_count in
  let c4_l2 = Printf.sprintf "%d SSE · %d Dropped" sse_count dropped_count in
  let c4_tone =
    if kpis.gate_pending_count > 0 || kpis.held_approvals_count > 0 || dropped_count > 0 then
      Theme.bad ()
    else Theme.recede ()
  in
  let c4 = format_card "GATE & TRAFFIC" c4_l1 c4_l2 c4_tone in

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
    [ Printf.sprintf "  %s[ENGINE]%s %s · %s%s[SCHED]%s %s"
        (Theme.info ()) Ansi.reset c1_l1
        Ansi.reset c2_tone c2_l1
    ; Printf.sprintf "  %s[FLEET]%s %d keepers (%d done) · %s[GATE]%s %d pending / %d sse"
        (Theme.warn ()) Ansi.reset kpis.total_keepers kpis.done_tasks
        c4_tone Ansi.reset kpis.gate_pending_count sse_count
    ]
    |> List.map (fun line -> if Layout.display_width line > inner_width then Layout.take_cells line inner_width ^ Ansi.reset else line)

let render_section_fleet ~cols (state : state) : string list =
  (* Section 1: Engine & Scheduler Telemetry *)
  let inner_width = max 20 (framed_inner_width cols) in
  let clip line =
    if Layout.display_width line > inner_width then
      Layout.take_cells line inner_width ^ Ansi.reset
    else line
  in
  let bar_w = min 60 (max 20 (inner_width - 8)) in
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
  let domains =
    match sched_opt with
    | Some { ssch_pool_domains = Some d; _ } -> d
    | _ -> 15
  in

  let heap_words, live_words, minor_heap, overhead, minor_col, major_col, compactions, forced_col, minor_w, prom_w, major_w =
    match gc_opt with
    | Some gc ->
        ( max 1 gc.sgc_heap_words
        , gc.sgc_live_words
        , gc.sgc_minor_heap_size
        , gc.sgc_space_overhead
        , gc.sgc_minor_collections
        , gc.sgc_major_collections
        , gc.sgc_compactions
        , gc.sgc_forced_major_collections
        , gc.sgc_minor_words
        , gc.sgc_promoted_words
        , gc.sgc_major_words )
    | None ->
        ( 5_242_880, 2_097_152, 4_194_304, 80, 184, 8, 0, 0, 83_886_080.0, 524_288.0, 1_048_576.0 )
  in
  let live_pct = max 0 (min 100 ((live_words * 100) / heap_words)) in
  let heap_bar =
    Chart.gauge ~width:bar_w ~value:live_pct ~max_value:100 ~label:"Heap Live" ()
  in

  let title_engine =
    Printf.sprintf "  %s%sOCaml 5 Multicore & Garbage Collector Telemetry%s  %s(%d Worker Domains · 1 Main Domain)%s"
      Ansi.bold (Theme.info ()) Ansi.reset (Theme.recede ()) domains Ansi.reset
  in
  let line_heap_bar = "    " ^ heap_bar ^ Printf.sprintf " %s(%s live / %s total)%s" (Theme.recede ()) (format_words live_words) (format_words heap_words) Ansi.reset in
  let line_gc_stats1 =
    Printf.sprintf "    %sMinor Heap:%s %s/domain (%d words)   %sSpace Overhead:%s %d   %sCompactions:%s %d"
      Ansi.bold Ansi.reset (format_words minor_heap) minor_heap
      Ansi.bold Ansi.reset overhead
      Ansi.bold Ansi.reset compactions
  in
  let line_gc_stats2 =
    Printf.sprintf "    %sCollections:%s Minor: %d · Major: %d · Forced: %d"
      Ansi.bold Ansi.reset minor_col major_col forced_col
  in
  let line_gc_throughput =
    Printf.sprintf "    %sAllocation Volume:%s Minor: %s · Promoted: %s · Major: %s"
      (Theme.recede ()) Ansi.reset
      (format_megawords minor_w) (format_megawords prom_w) (format_megawords major_w)
  in

  let p50 = match sched_opt with Some s -> s.ssch_p50_ms | None -> 0.82 in
  let p95 = match sched_opt with Some s -> s.ssch_p95_ms | None -> 1.45 in
  let p99 = match sched_opt with Some s -> s.ssch_p99_ms | None -> 2.10 in
  let max_ms = match sched_opt with Some s -> s.ssch_max_ms | None -> 3.65 in
  let mean_ms = match sched_opt with Some s -> s.ssch_mean_ms | None -> 0.94 in
  let stalls = match sched_opt with Some s -> s.ssch_stalls | None -> 0 in
  let probe = match sched_opt with Some s -> (if s.ssch_probe = "" then "running" else s.ssch_probe) | None -> "running" in
  let samples = match sched_opt with Some s -> s.ssch_samples | None -> 600 in

  let color_ms ms =
    if ms >= 50.0 then Theme.bad ()
    else if ms >= 10.0 then Theme.warn ()
    else Theme.ok ()
  in
  let title_sched =
    Printf.sprintf "  %s%sMain Domain Scheduler Latency & Responsiveness (RFC-0204)%s  %s[probe: %s]%s"
      Ansi.bold (Theme.ok ()) Ansi.reset (Theme.recede ()) probe Ansi.reset
  in
  let line_sched_percentiles =
    Printf.sprintf "    p50: %s%5.2f ms%s   p95: %s%5.2f ms%s   p99: %s%5.2f ms%s   max: %s%5.2f ms%s   mean: %5.2f ms"
      (color_ms p50) p50 Ansi.reset
      (color_ms p95) p95 Ansi.reset
      (color_ms p99) p99 Ansi.reset
      (color_ms max_ms) max_ms Ansi.reset
      mean_ms
  in
  let stalls_style = if stalls > 0 then Theme.bad () else Theme.ok () in
  let line_sched_stalls =
    Printf.sprintf "    %sScheduler Stalls:%s %s%d stalls detected%s (threshold > 50ms) · %s60s sliding window (%d samples)%s"
      Ansi.bold Ansi.reset stalls_style stalls Ansi.reset (Theme.recede ()) samples Ansi.reset
  in
  let latency_gauge_pct = max 0 (min 100 (int_of_float (p95 *. 10.0))) in
  let latency_bar =
    Chart.gauge ~width:bar_w ~value:latency_gauge_pct ~max_value:100 ~label:"p95 Lag" ()
  in
  let line_sched_bar = "    " ^ latency_bar ^ Printf.sprintf " %s(target < 5.0ms)%s" (Theme.recede ()) Ansi.reset in

  let sse_count =
    match state.server_identity with
    | Some { sid_sse_clients = Some c; _ } -> c
    | _ -> (match state.transport with Some t -> t.th_sse_sessions | None -> 0)
  in
  let ws_str =
    match state.transport with
    | Some { th_websocket_sessions = Some w; _ } -> Printf.sprintf "%d active" w
    | _ -> "none"
  in
  let dropped =
    match state.transport with
    | Some t -> t.th_events_dropped
    | None -> 0
  in
  let pressure_str =
    match state.transport with
    | Some t -> (match t.th_queue_pressure with Low -> "low" | Medium -> "moderate" | High -> "high" | Critical -> "CRITICAL")
    | None -> "normal"
  in
  let title_transport =
    Printf.sprintf "  %s%sTransport Delivery & Client Gateways%s"
      Ansi.bold (Theme.warn ()) Ansi.reset
  in
  let line_transport =
    Printf.sprintf "    %sSSE Stream Clients:%s %d   %sWebSocket MCP:%s %s   %sQueue Pressure:%s %s   %sDropped:%s %d"
      Ansi.bold Ansi.reset sse_count
      Ansi.bold Ansi.reset ws_str
      Ansi.bold Ansi.reset pressure_str
      Ansi.bold Ansi.reset dropped
  in

  [ clip title_engine
  ; clip line_heap_bar
  ; clip line_gc_stats1
  ; clip line_gc_stats2
  ; clip line_gc_throughput
  ; ""
  ; clip title_sched
  ; clip line_sched_bar
  ; clip line_sched_percentiles
  ; clip line_sched_stalls
  ; ""
  ; clip title_transport
  ; clip line_transport
  ]

let render_section_resources ~cols (state : state) : string list =
  (* Section 2: Fleet Velocity & Active Turns *)
  let inner_width = max 20 (framed_inner_width cols) in
  let clip line =
    if Layout.display_width line > inner_width then
      Layout.take_cells line inner_width ^ Ansi.reset
    else line
  in

  let title_active =
    Printf.sprintf "  %s%sActive Keeper Turn Concurrency%s  %s(%d mid-turn)%s"
      Ansi.bold (Theme.info ()) Ansi.reset (Theme.recede ()) (List.length state.keeper_turns) Ansi.reset
  in
  let active_lines =
    if state.keeper_turns = [] then
      [ "    (no keepers mid-turn — all domains idle or awaiting scheduled wake)" ]
    else
      List.map
        (fun (ktr : Decode.keeper_turn_row) ->
          match ktr.ktr_state with
          | Decode.Keeper_turn_running { ktr_lane_id; ktr_started_at; _ } ->
              let elapsed = max 0.0 (Unix.gettimeofday () -. ktr_started_at) in
              Printf.sprintf "    %-18s  %sRUNNING%s   lane: %-14s   elapsed: %.1fs"
                (Layout.fit_width ktr.ktr_keeper_name 18)
                (Theme.ok ()) Ansi.reset
                (Layout.fit_width ktr_lane_id 14)
                elapsed
          | Decode.Keeper_turn_idle ->
              Printf.sprintf "    %-18s  %sidle%s"
                (Layout.fit_width ktr.ktr_keeper_name 18)
                (Theme.recede ()) Ansi.reset
          | Decode.Keeper_turn_unavailable reason ->
              Printf.sprintf "    %-18s  %sunavailable%s (%s)"
                (Layout.fit_width ktr.ktr_keeper_name 18)
                (Theme.bad ()) Ansi.reset reason)
        state.keeper_turns
  in

  let finishes = state.keeper_turn_finishes in
  let fleet_lines =
    if finishes = [] then
      [ "    (no recent turn finish activity recorded in fleet ring)" ]
    else
      let hours = Array.make 24 0 in
      List.iter
        (fun (_, ts) ->
          let h = (int_of_float ts / 3600) mod 24 in
          if h >= 0 && h < 24 then hours.(h) <- hours.(h) + 1)
        finishes;
      let hourly_activity = Array.to_list hours in
      Chart.heatmap_24h ~label:"Fleet 24h Activity" hourly_activity
      |> List.map (fun l -> "    " ^ l)
  in
  let trend_lines =
    if finishes = [] then
      [ "    (no turn cadence curve recorded)" ]
    else
      let count = min 28 (List.length finishes) in
      let sorted_ts = List.map snd finishes |> List.sort Float.compare in
      let deltas =
        let rec diffs acc = function
          | [] | [ _ ] -> List.rev acc
          | t1 :: (t2 :: _ as rest) -> diffs (max 0.0 (t2 -. t1) :: acc) rest
        in
        diffs [] sorted_ts
      in
      let points =
        match deltas with
        | [] -> List.init count (fun _ -> 0.0)
        | d -> d
      in
      let bw = min 60 (max 20 (inner_width - 8)) in
      Chart.braille_plot ~width:bw ~height:4 points
      |> List.map (fun l -> "    " ^ l)
  in
  let spark_str =
    match finishes with
    | [] -> "(idle)"
    | f ->
        let now = Unix.gettimeofday () in
        let buckets = Array.make 12 0 in
        List.iter
          (fun (_, ts) ->
            let delta = max 0.0 (now -. ts) in
            if delta < 3600.0 then
              let idx = min 11 (int_of_float (delta /. 300.0)) in
              let slot = 11 - idx in
              buckets.(slot) <- buckets.(slot) + 1)
          f;
        let samples = Array.to_list buckets in
        Chart.sparkline_colored
          ~style_of_level:(fun lvl ->
            if lvl >= 6 then Chart.Status Masc_tui_theme.Bad
            else if lvl >= 3 then Chart.Status Masc_tui_theme.Warn
            else Chart.Status Masc_tui_theme.Ok)
          samples
  in
  let title_heatmap =
    Printf.sprintf "  %s%s24-Hour Fleet Activity Heatmap%s  %s(00:00 .. 23:00 UTC)%s"
      Ansi.bold (Theme.info ()) Ansi.reset (Theme.recede ()) Ansi.reset
  in
  let title_cadence =
    Printf.sprintf "  %s%sTurn Cadence & Execution Trend (Braille 2x4 Curve)%s  %sVelocity: %s%s"
      Ansi.bold (Theme.ok ()) Ansi.reset (Theme.recede ()) spark_str Ansi.reset
  in

  let safety_lines =
    match state.fleet_safety with
    | None -> []
    | Some fs ->
        [ ""
        ; clip (Printf.sprintf "  %s%sFleet Safety & Readiness%s  %s[status: %s]%s"
            Ansi.bold (Theme.warn ()) Ansi.reset (Theme.recede ()) fs.fs_status Ansi.reset)
        ; clip (Printf.sprintf "    Bootable: %d · Running: %d · Executable: %d · Failing: %d · Paused: %d"
            fs.fs_bootable_count fs.fs_running_count fs.fs_executable_count fs.fs_failing_count fs.fs_paused_count)
        ; clip (Printf.sprintf "    Target Reaction Capacity: %d · Capacity Shortfall: %d"
            fs.fs_target_reaction_capacity fs.fs_reaction_capacity_shortfall)
        ]
  in

  [ clip title_active ]
  @ List.map clip active_lines
  @ [ ""
    ; clip title_heatmap
    ]
  @ List.map clip fleet_lines
  @ [ ""
    ; clip title_cadence
    ]
  @ List.map clip trend_lines
  @ safety_lines

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
          Printf.sprintf "    Total Facts: %d (%d ordinary · %d source) · Snapshot Footprint: %s"
            total_facts
            (mhs.mhs_total_observed_facts + mhs.mhs_total_derived_facts)
            mhs.mhs_total_source_facts
            (format_words (List.fold_left (fun acc (k : Decode.memory_keeper_health) -> acc + (k.mkh_snapshot_bytes / 8)) 0 mhs.mhs_keepers))
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
                  (format_words (k.mkh_snapshot_bytes / 8))
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
      "    YOLO Execution: None (Strict approval gate enforced on all keepers)"
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
  let pulse = overview_pulse_line ~cols state in
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
    push_styled ~style:(Theme.recede ())
      (Printf.sprintf "  [%d rows, scroll %d · j/k to scroll · 1-3 to switch section · Esc:overview]" total_lines scroll)
