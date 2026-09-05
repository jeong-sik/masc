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
    Chart.gauge ~width:16 ~value:health_pct ~max_value:100 ~label:"Health" ()
  in
  let text =
    Printf.sprintf "  %sFleet Pulse:%s %s  %s  %s(%d keepers · %d active · %d tasks)%s"
      Ansi.bold Ansi.reset spark health_bar
      (Theme.recede ()) kpis.total_keepers kpis.active_keepers kpis.total_tasks
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
  let p1 = pill Section_fleet 1 "Fleet & Velocity" in
  let p2 = pill Section_resources 2 "Keeper Resources" in
  let p3 = pill Section_tools 3 "Tool Invocations" in
  let p4 = pill Section_latency 4 "Latency Waterfall" in
  let line = Printf.sprintf "  %sSections [1-4 / s]:%s  %s  %s  %s  %s"
    Ansi.bold Ansi.reset p1 p2 p3 p4
  in
  if Layout.display_width line > inner_width then
    Layout.take_cells line inner_width ^ Ansi.reset
  else line

let repeat_glyph glyph count =
  if count <= 0 then "" else String.concat "" (List.init count (fun _ -> glyph))
;;

let render_kpi_cards ~cols (kpis : metrics_kpis) : string list =
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
    |> List.map (fun line -> if Layout.display_width line > inner_width then Layout.take_cells line inner_width ^ Ansi.reset else line)

let render_section_fleet ~cols (state : state) : string list =
  let inner_width = max 20 (framed_inner_width cols) in
  let clip line =
    if Layout.display_width line > inner_width then
      Layout.take_cells line inner_width ^ Ansi.reset
    else line
  in
  let finishes = state.keeper_turn_finishes in
  let fleet_lines =
    if finishes = [] then
      [ "  (no turn finish activity recorded in fleet state)" ]
    else
      let hours = Array.make 24 0 in
      List.iter
        (fun (_, ts) ->
          let h = (int_of_float ts / 3600) mod 24 in
          if h >= 0 && h < 24 then hours.(h) <- hours.(h) + 1)
        finishes;
      let hourly_activity = Array.to_list hours in
      Chart.heatmap_24h ~label:"Fleet 24h Activity" hourly_activity
      |> List.map (fun l -> "  " ^ l)
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
  let title1 =
    Printf.sprintf "  %s%s24-Hour Fleet Activity Heatmap%s  %s(00:00 .. 23:00 UTC)%s"
      Ansi.bold (Theme.info ()) Ansi.reset (Theme.recede ()) Ansi.reset
  in
  let title2 =
    Printf.sprintf "  %s%sTurn Cadence & Execution Trend (Braille 2x4 Curve)%s  %sVelocity: %s%s"
      Ansi.bold (Theme.ok ()) Ansi.reset (Theme.recede ()) spark_str Ansi.reset
  in
  [ clip title1 ]
  @ List.map clip fleet_lines
  @ [ ""
    ; clip title2
    ]
  @ List.map clip trend_lines

let render_section_resources ~cols (state : state) : string list =
  let inner_width = max 20 (framed_inner_width cols) in
  let clip line =
    if Layout.display_width line > inner_width then
      Layout.take_cells line inner_width ^ Ansi.reset
    else line
  in
  (* Facts and snapshot bytes are counts with no capacity: memory OS declares
     no fact ceiling and no snapshot size limit, so a bar for either would
     be drawn against a number this pane made up (it was facts*2 and 200 KiB,
     #33297). They are shown as the readings they are, the way the Memory
     pane shows them. *)
  let header =
    [ clip
        (Printf.sprintf "  %s%sKeeper Memory%s"
           Ansi.bold (Theme.info ()) Ansi.reset)
    ; clip (Printf.sprintf "  %-16s  %s" "KEEPER" "FACTS · SNAPSHOT")
    ]
  in
  let rows =
    match state.memory_health with
    | None ->
        if state.keepers = [] then
          [ "  (no keepers registered in fleet)" ]
        else
          List.map
            (fun (k : keeper) ->
              Printf.sprintf "  %s  %s(memory telemetry not loaded — press m in Memory to load)%s"
                (Layout.fit_width k.k_name 16)
                (Theme.recede ()) Ansi.reset)
            state.keepers
    | Some mhs ->
        if mhs.mhs_keepers = [] then
          [ "  (no keepers with a memory config or snapshot)" ]
        else
          List.map
            (fun (k : Masc.Tui_decode.memory_keeper_health) ->
              Printf.sprintf "  %s  %s%4d ord · %s%s"
                (Layout.fit_width k.mkh_keeper_id 16)
                (Theme.recede ()) k.mkh_facts
                (Masc_tui_context_inspector.format_bytes k.mkh_snapshot_bytes)
                Ansi.reset)
            mhs.mhs_keepers
  in
  header @ List.map clip rows

let render_section_tools ~cols (state : state) : string list =
  let inner_width = max 20 (framed_inner_width cols) in
  let clip line =
    if Layout.display_width line > inner_width then
      Layout.take_cells line inner_width ^ Ansi.reset
    else line
  in
  let bar_w = min 65 (max 20 (inner_width - 6)) in
  let title =
    clip
      (Printf.sprintf "  %s%sGate Tool Operation Frequency%s  %s(pending & approval queue)%s"
         Ansi.bold (Theme.info ()) Ansi.reset (Theme.recede ()) Ansi.reset)
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
  if Hashtbl.length counts = 0 then
    [ title; "  (no active gate tool operations recorded in fleet state)" ]
  else
    let items =
      Hashtbl.fold
        (fun name count acc ->
          { Chart.name; count; style = Some (Chart.Status Masc_tui_theme.Ok) } :: acc)
        counts []
      |> List.sort (fun (a : Chart.bar_item) (b : Chart.bar_item) ->
             Int.compare b.count a.count)
    in
    let bar_lines =
      Chart.distribution_bars ~width:bar_w items
      |> List.map (fun l -> clip ("  " ^ l))
    in
    title :: bar_lines

let render_section_latency ~cols (_state : state) : string list =
  let inner_width = max 20 (framed_inner_width cols) in
  let clip line =
    if Layout.display_width line > inner_width then
      Layout.take_cells line inner_width ^ Ansi.reset
    else line
  in
  let title =
    Printf.sprintf "  %s%sTurn Execution Latency Waterfall%s  %s(telemetry tracer)%s"
      Ansi.bold (Theme.info ()) Ansi.reset (Theme.recede ()) Ansi.reset
  in
  (* Every line goes through [clip], not only the title: the second body line
     is 91 cells and the section contract is one line per row within
     [inner_width]. *)
  List.map clip
    [ title
    ; "  (turn execution timing waterfall breakdown unavailable — requires backend latency tracer)"
    ; "  (individual keeper turn latency samples are recorded in Keeper details)"
    ]

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
      (Printf.sprintf "  [%d rows, scroll %d · j/k to scroll · 1-4 to switch section]" total_lines scroll)
