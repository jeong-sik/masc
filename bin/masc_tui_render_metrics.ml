open Masc_tui_types
open Masc_tui_ansi
module Decode = Masc.Tui_decode
module Braille = Masc_tui_braille
module Chart = Masc_tui_chart
module Layout = Masc_tui_message_layout
module Rows = Masc_tui_rows
module Count = Masc_tui_value.Count
module Unknown = Masc_tui_value.Unknown

module Task_flow = Masc_tui_task_flow

type turn_counts = { running : int; idle : int; unavailable : int }
type metrics_kpis = {
  total_keepers : int;
  paused_keepers : int;
  turns : turn_counts option;
  tasks : Task_flow.counts option;
  gate_pending_count : int option;
  held_approvals_count : int option;
}

(* Two ways a source can have no reading, and the difference is who wrote the
   string. [Read_failed] carries the loader's own message, which names its
   subject and its verdict -- "memory health load failed: HTTP 503: ..." --
   and needs nothing in front of it. [Unavailable] carries the server's reason
   for a source it will not serve, which is a reason and nothing else, so the
   row says what state it is naming before it.

   One constructor held both, and the row put "unavailable: " in front of
   either. In front of a loader's message that was the subject and the verdict
   a second time, and it pushed the row past the pane: at a hundred and fifty
   columns beside the roster, three of the four Gate and Memory rows were cut
   before their reason ended. *)
type 'a observation =
  | Not_observed
  | Current of 'a
  | Read_failed of string
  | Unavailable of string
  | Stale of string

let observe_source ~observed ~error ?unavailable value =
  match error, unavailable, observed with
  | Some detail, _, true -> Stale detail
  | Some detail, _, false -> Read_failed detail
  | None, Some detail, _ -> Unavailable detail
  | None, None, true -> Current value
  | None, None, false -> Not_observed

let current_value = function
  | Current value -> Some value
  | Not_observed | Read_failed _ | Unavailable _ | Stale _ -> None

let gate_observation (state : state) =
  observe_source ~observed:state.gate_snapshot_observed ~error:state.gate_error
    ?unavailable:state.gate_queue_unavailable state.gate_pending

let held_observation (state : state) =
  observe_source ~observed:state.keeper_tool_approvals_observed
    ~error:state.keeper_tool_approvals_error state.keeper_tool_approvals

(* A count in a card, or the mark for why there is none (RFC
   tui-one-screen-grammar section 6.4). [Unavailable] is a source the server
   could not read from its own store, so it is no more read than a request
   that failed; a refresh that failed draws as failed too, not as the count
   an earlier read left behind. *)
let observation_count observation =
  match observation with
  | Current rows -> Count.grouped (List.length rows)
  | Not_observed -> Unknown.(glyph Unread)
  | Read_failed _ | Unavailable _ | Stale _ -> Unknown.(glyph Read_failed)

(* A section row's value. Without one, the row names the state of the
   reading in RFC-0519 section 2's words, then the reason the source gave;
   [current] says what a current reading reads as. A loader's message already
   names its subject and its verdict, so it stands alone. The card above the
   section draws the same observation as a mark ({!observation_count}). *)
let observation_detail_with ~ko ~current observation =
  match observation with
  | Current value -> current value
  | Not_observed -> field_unread ~ko
  | Read_failed detail -> Terminal_text.single_line detail
  | Unavailable detail -> field_failed ~ko ^ ": " ^ Terminal_text.single_line detail
  | Stale detail -> field_stale ~ko ^ " \xc2\xb7 " ^ Terminal_text.single_line detail

let observation_detail ~ko observation =
  observation_detail_with ~ko
    ~current:(fun rows -> Count.grouped (List.length rows))
    observation

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
    (* The number the row wants, counted straight off the field that holds
       it. The row used to draw "N configured · M unpaused" and leave the
       reader to subtract, and the subtraction is where the bug was: the
       count skipped a declared keeper as well as a paused one, so every
       declared keeper sat inside the difference a reader reads as paused.
       A word beside a number should name what that number counts. *)
    paused_keepers =
      List.length
        (List.filter (fun (keeper : keeper) -> keeper.k_paused) state.keepers);
    turns;
    tasks = Option.map (fun flow -> flow.Task_flow.current) state.task_flow;
    gate_pending_count = Option.map List.length (current_value (gate_observation state));
    held_approvals_count = Option.map List.length (current_value (held_observation state)) }

let format_words words =
  Masc_tui_context_inspector.format_bytes (max 0 words * 8)

let format_megawords words =
  let mw = Float.abs words /. 1_000_000.0 in
  if mw >= 1000.0 then Printf.sprintf "%.1f GW" (mw /. 1000.0)
  else if mw >= 1.0 then Printf.sprintf "%.1f MW" mw
  else Printf.sprintf "%.0f kW" (words /. 1000.0)

(* The probe's state in one word, without a stopped probe's reason: the
   word a card edge carries (RFC tui-one-screen-grammar section 2). *)
let scheduler_probe_state_word ~ko = function
  | Scheduler_lag.Not_started -> if ko then "시작 전" else "not started"
  | Scheduler_lag.Running -> if ko then "실행 중" else "running"
  | Scheduler_lag.Stopped _ -> if ko then "멈춤" else "stopped"
  | Scheduler_lag.Cancelled -> if ko then "취소됨" else "cancelled"

(* Why a probe stopped: the exception it raised, as the server sent it. It is
   data, so a card writes it in its body, where it is not dropped whole when
   the edge is narrow, as a status word is. *)
let scheduler_stop_reason = function
  | Some (Decode.Probe_reported (Scheduler_lag.Stopped reason)) ->
      Some (Terminal_text.single_line reason)
  | Some
      ( Decode.Probe_reported
          Scheduler_lag.(Not_started | Running | Cancelled)
      | Decode.Probe_unknown _ )
  | None -> None

(* The probe's state in words, with a stopped probe's reason. A word from a
   server newer than this build is drawn as it came behind [?] (RFC
   tui-one-screen-grammar section 7.1). That word and a stopped probe's
   reason come off the wire, so both are escaped here, where the rows that
   ask for them cannot each forget. *)
let scheduler_probe_word ~ko = function
  | Decode.Probe_reported state as probe -> (
      let word = scheduler_probe_state_word ~ko state in
      match scheduler_stop_reason (Some probe) with
      | Some reason -> word ^ ": " ^ reason
      | None -> word)
  | Decode.Probe_unknown word -> "? " ^ Terminal_text.single_line word

let scheduler_probe_text ~ko = function
  | None -> Unknown.(glyph Unreported)
  | Some probe -> scheduler_probe_word ~ko probe

(* Which kind of state the probe is in (RFC tui-one-screen-grammar section
   7.2). A probe that raised failed: [Stopped] carries the exception's
   message. A probe whose switch was cancelled was stopped on purpose. A word
   this build does not know, and no probe at all, are [?]. *)
let scheduler_probe_symbol : Decode.scheduler_probe option -> Masc_tui_card.symbol =
  function
  | None | Some (Decode.Probe_unknown _) -> Masc_tui_card.Unknown Unknown.Unreported
  | Some (Decode.Probe_reported Scheduler_lag.Not_started) ->
      Masc_tui_card.Mark Masc_tui_value.Mark.Waiting
  | Some (Decode.Probe_reported Scheduler_lag.Running) ->
      Masc_tui_card.Mark Masc_tui_value.Mark.Under_way
  | Some (Decode.Probe_reported (Scheduler_lag.Stopped _)) ->
      Masc_tui_card.Mark Masc_tui_value.Mark.Failed
  | Some (Decode.Probe_reported Scheduler_lag.Cancelled) ->
      Masc_tui_card.Mark Masc_tui_value.Mark.Paused

(* The probe as a card's status: the mark says which kind of state it is and
   the word says which one. A stopped probe's reason is not a state word; the
   card's body writes it (scheduler_stop_reason). A word this build does not
   know reads [?] and the word as it came (RFC tui-one-screen-grammar section
   7.1); no probe at all is the [?] alone. [tone] is the colour the samples
   give the card. A failed probe takes the colour its mark means instead, so
   a card with no stalls does not draw a failure in the colour of one that is
   fine. *)
let scheduler_probe_status ~ko ~tone probe : Masc_tui_card.status =
  let symbol = scheduler_probe_symbol probe in
  let word =
    match probe with
    | None -> ""
    | Some (Decode.Probe_unknown word) -> Terminal_text.single_line word
    | Some (Decode.Probe_reported state) -> scheduler_probe_state_word ~ko state
  in
  let tone =
    match symbol with
    | Masc_tui_card.Mark Masc_tui_value.Mark.Failed -> Theme.bad ()
    | Masc_tui_card.Mark
        Masc_tui_value.Mark.(Settled | Under_way | Waiting | Paused | Caution | Yours)
    | Masc_tui_card.Unknown _ -> tone
  in
  { Masc_tui_card.symbol; word; tone }

let pulse_line ~cols (state : state) kpis =
  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  let inner_width = max 10 (framed_inner_width cols) in
  (* A count with no reading behind it draws the mark of why (RFC
     tui-one-screen-grammar section 6.4). *)
  let dim_lbl s = Theme.recede () ^ s ^ Ansi.reset in
  let sep = dim_lbl " · " in
  let turns = match kpis.turns with
    | None ->
      dim_lbl (say "턴 " "Turns ")
      ^ Unknown.glyph
          (match state.keeper_turns_error with
           | Some _ -> Unknown.Read_failed
           | None -> Unknown.Unread)
    | Some count ->
      let run = Count.grouped count.running
      and idle = Count.grouped count.idle
      and unavail = Count.grouped count.unavailable in
      if ko then
        dim_lbl "턴: 실행 중 " ^ run ^ sep
        ^ dim_lbl "대기 중 " ^ idle ^ sep
        ^ dim_lbl "확인 불가 " ^ unavail
      else
        dim_lbl "Turns: " ^ run ^ dim_lbl " running" ^ sep
        ^ idle ^ dim_lbl " idle" ^ sep
        ^ unavail ^ dim_lbl " unavailable"
  in
  let roster =
    match state.local_keepers, state.keepers_error with
    | Local_workspace_read, None ->
      Printf.sprintf (if ko then "키퍼 %s · 일시정지 %s" else "%s configured · %s paused")
        (Count.grouped kpis.total_keepers) (Count.grouped kpis.paused_keepers)
    | Local_workspace_unread, None -> say "키퍼 " "roster " ^ Unknown.(glyph Unread)
    | (Local_workspace_unread | Local_workspace_read | Local_workspace_failed _), Some _
    | Local_workspace_failed _, None ->
      say "키퍼 " "roster " ^ Unknown.(glyph Read_failed)
  in
  let text = Printf.sprintf "  %s  %s| %s%s"
      turns (Theme.recede ()) roster Ansi.reset in
  Layout.truncate_end inner_width text ^ Ansi.reset

(* The three sections as a tab strip, drawn the way the surface strip above
   every screen is: a mark on the one being read, the names beside it. It was
   "Sections [1-3 / s]: [1 ● Engine & Scheduler] [2 ○ Work & Outcomes] ...",
   which spelled the keys the footer already draws (1-3:section, s:cycle),
   wrote each name a second time beside [metrics_section_label], and was cut
   before the third name at 150 columns beside the Activity pane. The order is
   the order 1, 2 and 3 select. *)
(* Why the server identity has no GC or scheduler block to draw: none has
   been read yet, the last read failed, or the one read did not carry it. *)
let identity_gap (state : state) =
  match state.server_identity, state.server_identity_error with
  | Some _, (None | Some _) -> Unknown.Unreported
  | None, Some _ -> Unknown.Read_failed
  | None, None -> Unknown.Unread

let section_pills_line ~ko ~cols ~(active : metrics_section) : string =
  let inner_width = max 10 (framed_inner_width cols) in
  let tab section = (metrics_section_label ~ko section, active = section, section) in
  let line =
    "  "
    ^ tab_strip
        ~width:(tab_strip_width ~cols ~before:"  " ~after:"")
        ~press:(fun section text ->
          Masc_tui_press.(pressable (Press_metrics_section section)) text)
        (List.map tab [ Section_fleet; Section_resources; Section_tools ])
  in
  Layout.truncate_end inner_width line

(* Progressive KPI card tiers: 4x1 row on wide terminals, 2x2 grid on standard
   laptop/split terminals (80–155 cols), and compact summaries only when even a
   2-column card cannot hold [minimum_card_text_cells] of text without clipping
   numeric figures. *)
let minimum_card_text_cells = 32
let kpi_cards = 4
let kpi_card_gaps = 10
let kpi_card_gaps_2 = 6
let kpi_card_min_width = 18

type kpi_layout =
  | Cards_4 of { card_w : int; card_cells : int }
  | Cards_2x2 of { card_w : int; card_cells : int }
  | Compact

let kpi_layout ~cols =
  let inner_width = max 20 (framed_inner_width cols) in
  let card_w_4 = max kpi_card_min_width ((inner_width - kpi_card_gaps) / kpi_cards) in
  let card_cells_4 = Masc_tui_card.content_cells ~width:card_w_4 in
  if card_cells_4 >= minimum_card_text_cells then
    Cards_4 { card_w = card_w_4; card_cells = card_cells_4 }
  else
    let card_w_2 = max kpi_card_min_width ((inner_width - kpi_card_gaps_2) / 2) in
    let card_cells_2 = Masc_tui_card.content_cells ~width:card_w_2 in
    if card_cells_2 >= minimum_card_text_cells then
      Cards_2x2 { card_w = card_w_2; card_cells = card_cells_2 }
    else Compact

(* Telemetry's engine section: the view whose cards draw the engine graphs. *)
let engine_view_open (state : state) =
  state.view = Metrics && state.usage_telemetry_open
  && (match state.metrics_section with
      | Section_fleet -> true
      | Section_resources | Section_tools -> false)

(* Without cards, the two graphs share one row under the summary that names
   the engine and the scheduler, in that order, each half of what is left
   after the row's lead and the gap between them. *)
let compact_graph_lead = "  "
let compact_graph_gap = "  "

let compact_graph_cells ~cols =
  let inner_width = max 20 (framed_inner_width cols) in
  (inner_width - String.length compact_graph_lead - String.length compact_graph_gap) / 2

(* How many cells each engine graph is wide. *)
let engine_graph_cells ~cols =
  match kpi_layout ~cols with
  | Cards_4 { card_cells; _ } | Cards_2x2 { card_cells; _ } -> card_cells
  | Compact -> compact_graph_cells ~cols

(* Both engine graphs give their axis this many cells: the widest top either
   ladder below writes ("9.99ms", "59m59s"). The axis column then does not
   depend on the samples, so both graphs draw the same number of times, one
   ring keeps exactly those, and a top that changes width moves no dots (RFC
   tui-one-screen-grammar sections 5.6 and 8). *)
let engine_axis_cells = 6

(* The ring keeps as many samples as a graph draws times: two a cell of dots
   beside the axis column (RFC tui-one-screen-grammar section 5.6). *)
let engine_graph_capacity ~cols (state : state) =
  if engine_view_open state then
    Some (Braille.graph_times ~width:(engine_graph_cells ~cols) ~axis_cells:engine_axis_cells)
  else None

(* [numerator / denominator] rounded up, for a numerator of zero or more,
   without the overflow [numerator + denominator - 1] risks near [max_int]. *)
let div_up numerator denominator =
  (numerator / denominator) + if numerator mod denominator = 0 then 0 else 1

(* A rung of an axis ladder holds a figure below this; a larger one moves to
   the next rung. *)
let rung_limit = 1000
let bytes_per_word = 8.
let bytes_per_kb = 1024.
let tenths_per_minute = 600

(* The top of the heap axis: the held top of the heap graph
   (Masc_tui_engine_samples.graph), in bytes, in the smallest binary unit that
   keeps the figure below a thousand, with tenths below ten. Rounded up, so
   the text is never under the top the dots are scaled to. At
   most five cells ("999KB", "9.9GB"): the largest heap a 63-bit count of
   words can name is 32EB. *)
let heap_axis words =
  let bytes = Float.of_int (max 0 words) *. bytes_per_word in
  if bytes < Float.of_int rung_limit then Printf.sprintf "%.0fB" bytes
  else
    let rec rung size unit larger =
      let value = bytes /. size in
      let tenths = Float.ceil (value *. 10.) in
      if tenths < 100. then Printf.sprintf "%.1f%s" (tenths /. 10.) unit
      else
        let whole = Float.ceil value in
        match larger with
        | next :: rest when whole >= Float.of_int rung_limit ->
          rung (size *. bytes_per_kb) next rest
        | _ :: _ | [] -> Printf.sprintf "%.0f%s" whole unit
    in
    rung bytes_per_kb "KB" [ "MB"; "GB"; "TB"; "PB"; "EB" ]

(* The top of the p95 axis: the held top of the p95 graph, in whole
   microseconds. Hundredths of a millisecond below ten, tenths below a
   hundred, whole milliseconds below a second, tenths of a second below a
   minute, then the two-unit ladder of a finished span (section 6.2). Each
   rung rounds up, so the text is never under the top. At most six cells
   below a hundred thousand days, longer than a server runs and so than any
   lag it measures. *)
let p95_axis microseconds =
  let us = max 0 microseconds in
  let hundredths_ms = div_up us 10 in
  if hundredths_ms < rung_limit then
    Printf.sprintf "%d.%02dms" (hundredths_ms / 100) (hundredths_ms mod 100)
  else
    let tenths_ms = div_up us 100 in
    if tenths_ms < rung_limit then Printf.sprintf "%d.%dms" (tenths_ms / 10) (tenths_ms mod 10)
    else
      let ms = div_up us 1_000 in
      if ms < rung_limit then Printf.sprintf "%dms" ms
      else
        let tenths_s = div_up us 100_000 in
        if tenths_s < tenths_per_minute then
          Printf.sprintf "%d.%ds" (tenths_s / 10) (tenths_s mod 10)
        else Layout.span_text (Float.of_int (div_up us 1_000_000))

(* The quantity each engine graph draws, so it takes that quantity's ramp on
   every screen (RFC tui-one-screen-grammar 7.3). *)
let engine_series_tint = function
  | Masc_tui_engine_samples.Live_heap -> Theme.series_tint Masc_tui_theme.Memory
  | Masc_tui_engine_samples.Scheduler_p95 -> Theme.series_tint Masc_tui_theme.Latency

(* A card's graph row. Before the view's first sample it is the unread mark;
   with no room for dots, the number the card already wrote. *)
let engine_graph_row ~cells ~axis ~number series (state : state) =
  match
    Masc_tui_engine_samples.graph ~tint:(engine_series_tint series) ~width:cells
      ~axis_cells:engine_axis_cells ~axis series state.engine_samples
  with
  | Braille.Drawn rows -> String.concat "" rows
  | Braille.Never_read -> Unknown.(glyph Unread)
  | Braille.Too_narrow -> number

let render_kpi_cards ~cols (state : state) (kpis : metrics_kpis) : string list =
  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  let inner_width = max 20 (framed_inner_width cols) in
  let layout = kpi_layout ~cols in
  (* The engine view draws a graph row in the Engine and scheduler cards, so
     every card of the row is one row taller there. *)
  let graphs = engine_view_open state in
  let card_height = if graphs then 5 else 4 in
  let render_card ~card_w ?status ?count ?(role = Masc_tui_theme.Panel_neutral) ~title_style name lines =
    let style =
      { Masc_tui_card.border = Theme.border_muted ()
      ; focused_border = Theme.border_focus ()
      ; title_style = Ansi.bold ^ title_style
      ; reset = Ansi.reset
      }
    in
    Masc_tui_card.render ~ko ~style ~width:card_w ~height:card_height
      { Masc_tui_card.edge =
          { Masc_tui_card.name; key = None; status; count; focus = Masc_tui_card.Unfocused
          ; border_accent = Some (Theme.panel_border role); footer_keys = [] }
      ; body = (fun ~cells:_ -> lines) }
  in
  let gc_opt =
    Option.bind state.server_identity (fun id -> id.Decode.sid_gc)
  in
  let sched_opt =
    Option.bind state.server_identity (fun id -> id.Decode.sid_scheduler)
  in
  let identity_gap = identity_gap state in
  let domains = match sched_opt with
    | Some { ssch_pool_domains = Some count; _ } -> Count.grouped count
    | Some { ssch_pool_domains = None; _ } -> Unknown.(glyph Unreported)
    | None -> Unknown.glyph identity_gap
  in
  (* The worker count is data, so it is in the body: a card's edge holds
     its name, status and count (RFC tui-one-screen-grammar section 2). The
     first row is the heap and the workers: at most 29 cells for a heap under
     100 GB and up to 999 workers, so a card's 32 cells hold it whole. The
     live size goes to the end of the meter on the second row, the way the
     Task card puts its done count there. The heap, the live size and the
     workers on one row take 37 cells or more, so at the narrower card widths
     the cut took the workers off. The compact summary is one row wide enough
     for all three. *)
  let dim_lbl s = Theme.recede () ^ s ^ Ansi.reset in
  let sep = dim_lbl " · " in
  let workers_styled =
    if ko then dim_lbl "워커 " ^ domains else domains ^ dim_lbl " workers"
  in
  let c1_l1, c1_l2, c1_compact, c1_number = match gc_opt with
    | Some gc ->
      let heap_val = format_words gc.sgc_heap_words in
      let heap_styled = dim_lbl (say "힙 " "Heap ") ^ heap_val in
      let live = format_words gc.sgc_live_words in
      let live_line =
        match layout with
        | Cards_4 { card_cells; _ } | Cards_2x2 { card_cells; _ } when gc.sgc_heap_words > 0 ->
          Chart.meter ~width:card_cells ~value:gc.sgc_live_words
            ~max_value:(max 1 gc.sgc_heap_words)
            ~label:(say "점유" "Live") ~label_style:(Theme.recede ()) ~suffix:live
            (* The heap grows as the GC asks for more, so live words against
               it are a share, not a use of a limit. *)
            ~scale:(Chart.Series { paint = Theme.paint (); series = Masc_tui_theme.Memory })
            ~track_style:(Theme.recede ()) ~reset:Ansi.reset ()
        | Cards_4 _ | Cards_2x2 _ | Compact ->
          dim_lbl (say "사용 중 " "live ") ^ live ^ sep
          ^ dim_lbl (say "마이너 힙 " "minor ") ^ format_words gc.sgc_minor_heap_size
      in
      ( heap_styled ^ sep ^ workers_styled
      , live_line
      , heap_styled ^ sep ^ dim_lbl (say "사용 중 " "live ") ^ live ^ sep ^ workers_styled
      , live )
    | None ->
      let mark = Unknown.glyph identity_gap in
      let heap_styled = dim_lbl (say "힙 " "Heap ") ^ mark in
      ( heap_styled
      , dim_lbl (say "워커 " "Workers ") ^ domains
      , heap_styled ^ sep ^ workers_styled
      , mark )
  in
  (* The probe's state is the card's status, on its edge, so the body does
     not write the probe again. A stopped probe's reason is data, the last
     row of the body, after the sample summary and graph when those are
     drawn. The card counts the reason on its bottom edge if it is cut.
     A stopped probe takes no new samples, so the window empties and the
     reason moves up. *)
  let stop_reason =
    Option.to_list
      (scheduler_stop_reason (Option.bind sched_opt (fun s -> s.ssch_probe)))
  in
  let c2_l1, c2_rest, c2_tone, c2_status, c2_number = match sched_opt with
    | Some s when s.ssch_samples <= 0 ->
      ( dim_lbl (say "지연 표본 없음" "No latency samples"),
        [],
        "",
        scheduler_probe_status ~ko ~tone:(Theme.recede ()) s.ssch_probe,
        Unknown.(glyph Unreported) )
    | Some s ->
      let tone = if s.ssch_stalls > 0 then Theme.warn () else "" in
      let badge_tone = if s.ssch_stalls > 0 then Theme.warn () else Theme.ok () in
      let p95_val = Printf.sprintf "%.3fms" s.ssch_p95_ms in
      let max_val = Printf.sprintf "%.3fms" s.ssch_max_ms in
      let samples_val = Count.grouped s.ssch_samples in
      let stalls_val =
        let raw = Count.grouped s.ssch_stalls in
        if s.ssch_stalls > 0 then Theme.warn () ^ raw ^ Ansi.reset else raw
      in
      let row2 =
        if ko then
          dim_lbl "표본 " ^ samples_val ^ sep ^ dim_lbl "정체 " ^ stalls_val
        else
          samples_val ^ dim_lbl " samples" ^ sep ^ stalls_val ^ dim_lbl " stalls"
      in
      ( dim_lbl "p95 " ^ p95_val ^ sep ^ dim_lbl (say "최대 " "max ") ^ max_val,
        [ row2 ],
        tone,
        scheduler_probe_status ~ko ~tone:badge_tone s.ssch_probe,
        p95_val )
    (* One condition -- no scheduler reading at all -- so both halves of the
       card draw the same mark. *)
    | None ->
      let mark = Unknown.glyph identity_gap in
      ( dim_lbl "p95 " ^ mark,
        [ dim_lbl (say "표본 " "Samples ") ^ mark ],
        "",
        { Masc_tui_card.symbol = Masc_tui_card.Unknown identity_gap
        ; word = ""
        ; tone = Theme.recede () },
        mark )
  in
  (* With no task reading the edge has no count to write, and its mark says
     why, as the Attention card's does: a card that cannot count reads
     differently from one that has nothing to count. *)
  let c3_l1, c3_l2, c3_count, c3_status = match kpis.tasks with
    | Some count ->
      let total = Task_flow.total_count count in
      (* The total is the card's count, on its edge. The meter measures the
         done tasks against it and writes the done count alone, as the
         Engine card's meter writes the live size against the heap above. *)
      let done_line =
        match layout with
        | Cards_4 { card_cells; _ } | Cards_2x2 { card_cells; _ } when total > 0 ->
          Chart.meter ~width:card_cells ~value:count.completed
            ~max_value:(max 1 total)
            ~label:(say "완료" "Done") ~label_style:(Theme.recede ())
            ~suffix:(Count.grouped count.completed)
            ~scale:(Chart.Series { paint = Theme.paint (); series = Masc_tui_theme.Completion })
            ~track_style:(Theme.recede ()) ~reset:Ansi.reset ()
        | Cards_4 _ | Cards_2x2 _ | Compact ->
          let done_s = Count.grouped count.completed in
          let canc_s = Count.grouped count.cancelled in
          if ko then dim_lbl "완료 " ^ done_s ^ sep ^ dim_lbl "취소 " ^ canc_s
          else done_s ^ dim_lbl " done" ^ sep ^ canc_s ^ dim_lbl " cancelled"
      in
      let open_s = Count.grouped (Task_flow.open_count count) in
      let ver_s = Count.grouped count.awaiting_verification in
      let row1 =
        if ko then dim_lbl "열린 작업 " ^ open_s ^ sep ^ dim_lbl "검증 대기 " ^ ver_s
        else open_s ^ dim_lbl " open" ^ sep ^ ver_s ^ dim_lbl " verifying"
      in
      ( row1
      , done_line
      , Some (Masc_tui_card.Whole total)
      , None )
    | None ->
      let why =
        match state.tasks_error with
        | Some _ -> Unknown.Read_failed
        | None -> Unknown.Unread
      in
      let mark = Unknown.glyph why in
      ( dim_lbl (say "열린 작업 " "Open ") ^ mark
      , dim_lbl (say "완료 " "Done ") ^ mark
      , None
      , Some
          { Masc_tui_card.symbol = Masc_tui_card.Unknown why
          ; word = ""
          ; tone = Theme.recede () } )
  in
  let c4_l1 = dim_lbl "Gate " ^ observation_count (gate_observation state) in
  let c4_l2 = dim_lbl (say "보류된 호출 " "Tool holds ") ^ observation_count (held_observation state) in
  let is_failed = function
    | Read_failed _ | Unavailable _ | Stale _ -> true
    | Current _ | Not_observed -> false
  in
  let failed =
    is_failed (gate_observation state) || is_failed (held_observation state)
  in
  (* With a half unread, the edge says why and the body keeps the half that
     was read: [Gate 3] beside [Tool holds ◌]. *)
  let unread tone =
    Some
      { Masc_tui_card.symbol =
          Masc_tui_card.Unknown (if failed then Unknown.Read_failed else Unknown.Unread)
      ; word = ""
      ; tone }
  in
  let c4_tone, c4_status, c4_count =
    match kpis.gate_pending_count, kpis.held_approvals_count with
    | Some 0, Some 0 ->
      ( "",
        Some
          { Masc_tui_card.symbol = Masc_tui_card.Mark Masc_tui_value.Mark.Settled
          ; word = say "정상" "clear"
          ; tone = Theme.ok () },
        None )
    | Some g, Some h -> Theme.warn (), None, Some (Masc_tui_card.Whole (g + h))
    | Some n, None | None, Some n ->
      if n > 0 || failed then Theme.warn (), unread (Theme.warn ()), None
      else "", unread (Theme.recede ()), None
    | None, None ->
      if failed then Theme.warn (), unread (Theme.warn ()), None
      else "", unread (Theme.recede ()), None
  in

  let rec zip2 r1 r2 =
    match r1, r2 with
    | a :: t1, b :: t2 -> ("  " ^ a ^ "  " ^ b) :: zip2 t1 t2
    | [], _ | _ :: _, [] -> []
  in
  let rec zip4 r1 r2 r3 r4 =
    match r1, r2, r3, r4 with
    | a :: t1, b :: t2, c :: t3, d :: t4 ->
      ("  " ^ a ^ "  " ^ b ^ "  " ^ c ^ "  " ^ d) :: zip4 t1 t2 t3 t4
    | [], _, _, _
    | _ :: _, [], _, _
    | _ :: _, _ :: _, [], _
    | _ :: _, _ :: _, _ :: _, [] -> []
  in
  let make_cards ~card_w ~card_cells =
    let render_card = render_card ~card_w in
    let graph_row ~number series ~axis =
      if graphs then [ engine_graph_row ~cells:card_cells ~axis ~number series state ] else []
    in
    ( render_card ~role:Masc_tui_theme.Panel_memory ~title_style:"" (say "엔진" "Engine")
        ([ c1_l1; c1_l2 ]
         @ graph_row ~number:c1_number Masc_tui_engine_samples.Live_heap ~axis:heap_axis)
    , render_card ~role:Masc_tui_theme.Panel_attention ~status:c2_status ~title_style:c2_tone (say "스케줄러 지연" "Scheduler lag")
        ((c2_l1 :: c2_rest)
         @ graph_row ~number:c2_number Masc_tui_engine_samples.Scheduler_p95 ~axis:p95_axis
         @ stop_reason)
    , render_card ~role:Masc_tui_theme.Panel_fleet ?status:c3_status ?count:c3_count ~title_style:""
        (say "작업 현황" "Task snapshot") [ c3_l1; c3_l2 ]
    , render_card ~role:Masc_tui_theme.Panel_attention ?status:c4_status ?count:c4_count ~title_style:c4_tone
        (say "확인 필요" "Attention") [ c4_l1; c4_l2 ] )
  in
  match layout with
  | Cards_4 { card_w; card_cells } ->
    let c1, c2, c3, c4 = make_cards ~card_w ~card_cells in
    zip4 c1 c2 c3 c4
  | Cards_2x2 { card_w; card_cells } ->
    let c1, c2, c3, c4 = make_cards ~card_w ~card_cells in
    zip2 c1 c2 @ zip2 c3 c4
  | Compact ->
    let graphs_row =
      if graphs then
        let cells = compact_graph_cells ~cols in
        let graph ~number series ~axis =
          Layout.fit_width (engine_graph_row ~cells ~axis ~number series state) cells
        in
        [ compact_graph_lead
          ^ graph ~number:c1_number Masc_tui_engine_samples.Live_heap ~axis:heap_axis
          ^ compact_graph_gap
          ^ graph ~number:c2_number Masc_tui_engine_samples.Scheduler_p95 ~axis:p95_axis ]
      else []
    in
    (* One card to a row. Two cards shared the first row and were cut at
       the edge, which left "최" of 최대 and dropped the figure after it (RFC
       tui-one-screen-grammar §6.6). Packing them by their current width
       instead made the row count follow the figures: a latency gaining a
       digit moved every section below by a row (§8). A card wider than the
       row on its own wraps; nothing is cut. The engine graphs sit under the
       two cards they draw. *)
    let card tone title text = Printf.sprintf "%s%s[%s]%s %s" Ansi.bold tone title Ansi.reset text in
    let packed card =
      Layout.wrap_styled_words ~max_cells:(max 1 (inner_width - 2)) card
      |> List.map (fun row -> "  " ^ row)
    in
    packed (card "" (say "엔진" "Engine") c1_compact)
    @ packed (card c2_tone (say "지연" "Sched") c2_l1)
    @ graphs_row
    @ packed (card "" (say "작업" "Tasks") c3_l1)
    @ packed (card c4_tone (say "확인" "Holds") (c4_l1 ^ sep ^ c4_l2))

type session_entry = { event : event; run : int; rows : string list }
type session_block = { earlier : int; kept : session_entry list }

(* One TUI session event as the rows it takes at [width]: the clock and the
   error mark lead the first row, and the sentence wraps under its own first
   word. The events that run long are the ones that put the cause and the
   next step after the subject -- "runtime event feed closed: " and then
   why -- so a row cut at the pane's edge loses the part that says what to
   do, at any width. *)
let session_entry_rows ~now ~width ((event : event), run) =
  let mark =
    match session_event_mark event with
    | None -> ""
    | Some glyph ->
      Printf.sprintf "%s%s%s%s " Ansi.bold (Theme.bad ()) glyph Ansi.reset
  in
  let lead =
    Printf.sprintf "    %s[%s]%s %s" (Theme.recede ())
      (Masc_tui_value.Instant.cell_text Masc_tui_value.Instant.To_second ~now event.at)
      Ansi.reset mark
  in
  let lead_cells = Layout.display_width lead in
  let content = Terminal_text.single_line event.content in
  let text =
    if run > 1 then
      Printf.sprintf "%s %s\xc3\x97%d%s" content (Theme.recede ()) run Ansi.reset
    else content
  in
  match Layout.wrap_styled_words ~max_cells:(max 1 (width - lead_cells)) text with
  | [] -> [ lead ]
  | first :: continued ->
    let indent = String.make lead_cells ' ' in
    (lead ^ first) :: List.map (fun row -> indent ^ row) continued

(* Which events the block draws in [room] rows. Room is spent in rows, and an
   event is kept or left out whole: past the room the oldest ones go first
   and one row counts them, so the newest event is the last thing drawn. The
   newest event is kept even when it alone is taller than the room beside
   that count; the section scrolls, and a row pushed below the fold can be
   reached where a sentence cut at the edge cannot. *)
let session_block ~now ~width ?room events =
  let entries =
    Masc_tui_render_schedule.collapse_consecutive ~key:session_event_collapse_key
      events
    |> List.rev
    |> List.map (fun ((event : event), run) ->
           { event; run; rows = session_entry_rows ~now ~width (event, run) })
  in
  let rows_of entry = List.length entry.rows in
  let all = { earlier = 0; kept = entries } in
  match room, List.rev entries with
  | None, _ | Some _, [] -> all
  | Some room, _ when List.fold_left (fun used e -> used + rows_of e) 0 entries <= room ->
    all
  | Some room, (newest :: _ as newest_first) ->
    (* One row goes to the count of what was left out. *)
    let rec take used kept = function
      | entry :: older when used + rows_of entry <= room - 1 ->
        take (used + rows_of entry) (entry :: kept) older
      | _ :: _ | [] -> kept
    in
    let kept =
      match take 0 [] newest_first with
      | [] -> [ newest ]
      | _ :: _ as kept -> kept
    in
    { earlier = List.length entries - List.length kept; kept }

let render_section_fleet ?session_rows ~cols (state : state) =
  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  let inner_width = max 20 (framed_inner_width cols) in
  let clip text = Layout.truncate_end inner_width text ^ Ansi.reset in
  (* A block of this page is headed like every detail section (RFC
     tui-one-screen-grammar §5.2, §7.3). *)
  let title text = "  " ^ Section.styled_heading ~rule_style:(Theme.recede ()) text in
  let gc = Option.bind state.server_identity (fun identity -> identity.Decode.sid_gc) in
  let scheduler = Option.bind state.server_identity (fun identity -> identity.Decode.sid_scheduler) in
  (* Why a block the server identity holds has nothing in it. Not read yet is
     said in the word every surface uses for a reading not loaded; a failed
     read is the loader's own sentence, as the transport block draws it. *)
  let identity_gap =
    match state.server_identity, state.server_identity_error with
    | Some _, (None | Some _) -> say "서버가 보고하지 않음" "not reported by the server"
    | None, Some error -> Terminal_text.single_line error
    | None, None -> field_unread ~ko
  in
  let reported_count =
    Option.fold ~none:Unknown.(glyph Unreported) ~some:Count.grouped
  in
  let gc_lines = match gc with
    | None -> [ "    " ^ identity_gap ]
    | Some gc ->
      let meter_rows =
        if gc.sgc_heap_words > 0 then
          [ "    "
            ^ Chart.meter ~width:(min 56 (max 24 (inner_width - 4)))
                ~value:gc.sgc_live_words ~max_value:(max 1 gc.sgc_heap_words)
                ~label:(say "점유율" "Occupancy")
                ~scale:(Chart.Series { paint = Theme.paint (); series = Masc_tui_theme.Memory })
                ~track_style:(Theme.recede ()) ~reset:Ansi.reset ()
          ]
        else []
      in
      [ Printf.sprintf
          (if ko then "    힙 %s · 사용 중 %s · 마이너 힙 설정 %s"
           else "    Heap %s · live %s · configured minor heap %s")
          (format_words gc.sgc_heap_words) (format_words gc.sgc_live_words)
          (format_words gc.sgc_minor_heap_size) ]
      @ meter_rows
      @ [ Printf.sprintf
            (if ko then "    수거: 마이너 %s · 메이저 %s · 강제 메이저 %s · 압축 %s"
             else "    Collections: minor %s · major %s · forced %s · compactions %s")
            (Count.grouped gc.sgc_minor_collections) (Count.grouped gc.sgc_major_collections)
            (Count.grouped gc.sgc_forced_major_collections) (Count.grouped gc.sgc_compactions)
        ; Printf.sprintf
            (if ko then "    할당 누계: 마이너 %s · 승격 %s · 메이저 %s"
             else "    Allocation totals: minor %s · promoted %s · major %s")
            (format_megawords gc.sgc_minor_words) (format_megawords gc.sgc_promoted_words)
            (format_megawords gc.sgc_major_words) ]
  in
  let scheduler_lines = match scheduler with
    | None -> [ "    " ^ identity_gap ]
    | Some sched when sched.ssch_samples <= 0 ->
      [ say "    서버 표본 구간에 지연 표본 없음" "    No latency samples in the producer window"
      ; Printf.sprintf
          (if ko then "    프로브 %s · 워커 도메인 %s" else "    Probe %s · worker domains %s")
          (scheduler_probe_text ~ko sched.ssch_probe)
          (reported_count sched.ssch_pool_domains) ]
    | Some sched ->
      [ Printf.sprintf "    p50 %.3fms · p95 %.3fms · p99 %.3fms"
          sched.ssch_p50_ms sched.ssch_p95_ms sched.ssch_p99_ms
      ; Printf.sprintf
          (if ko then "    최대 %.3fms · 평균 %.3fms · 표본 %s"
           else "    Maximum %.3fms · mean %.3fms · %s samples")
          sched.ssch_max_ms sched.ssch_mean_ms (Count.grouped sched.ssch_samples)
      ; Printf.sprintf
          (if ko then "    서버가 센 정체 %s · 프로브 %s · 워커 도메인 %s"
           else "    Producer-reported stalls %s · probe %s · worker domains %s")
          (Count.grouped sched.ssch_stalls)
          (scheduler_probe_text ~ko sched.ssch_probe)
          (reported_count sched.ssch_pool_domains)
      ; say "    스케줄러 지연은 런타임 응답 속도이며 작업 결과가 아닙니다."
          "    Scheduler delay measures runtime responsiveness, not task output." ]
  in
  let path_word = function
    | Masc.Transport_metrics.Grpc_subscribe -> say "gRPC 구독" "gRPC subscribe"
    | Websocket -> "WebSocket"
    | Sse -> "SSE"
    | Streamable_http -> "Streamable HTTP"
  in
  let pressure_word = function
    | Masc.Transport_metrics.Steady -> say "안정" "steady"
    | Watch -> say "주의" "watch"
    | High -> say "높음" "high"
  in
  (* A failed read is the loader's own sentence, which names its subject and
     its verdict, so it is not drawn as a read not made yet. *)
  let transport_lines = match state.transport, state.transport_error with
    | Some transport, _ ->
      [ Printf.sprintf
          (if ko then "    주 경로 %s · gRPC %s" else "    Primary path %s · gRPC %s")
          (path_word transport.th_primary_path)
          (Option.fold ~none:(say "꺼짐" "off") ~some:(Printf.sprintf ":%d")
             transport.th_grpc_port)
      ; Printf.sprintf
          (if ko then "    SSE 세션 %s · WebSocket 세션 %s · 버린 이벤트 %s"
           else "    SSE sessions %s · WebSocket sessions %s · dropped events %s")
          (Count.grouped transport.th_sse_sessions)
          (reported_count transport.th_websocket_sessions)
          (Count.grouped transport.th_events_dropped)
      ; say "    큐 압력: " "    Queue pressure: " ^ pressure_word transport.th_queue_pressure ]
    | None, Some error -> [ "    " ^ Terminal_text.single_line error ]
    | None, None -> [ "    " ^ field_unread ~ko ]
  in
  (* This TUI's own subscription to the runtime event feed. The count sits
     straight after the state word in both states, the way the Activity
     status row puts it, so a closed feed's number reads as the frames it
     carried. *)
  let feed_line =
    say "    런타임 이벤트 수신: " "    Runtime event feed: "
    ^
    match state.observer with
    | Observer_off -> say "꺼짐" "off"
    | Observer_opening ->
        Theme.info () ^ Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way ^ " "
        ^ say "연결 중" "opening" ^ Ansi.reset
    | Observer_live { events; _ } ->
        Printf.sprintf (if ko then "수신 중 %s" else "live %s") (Count.grouped events)
    | Observer_closed_after_live { events; reason; _ } ->
        Printf.sprintf (if ko then "닫힘 %s · %s" else "closed %s · %s")
          (Count.grouped events) (Terminal_text.single_line reason)
    | Observer_closed_before_answer { reason; _ } ->
        say "시작 실패 · " "failed to open · " ^ Terminal_text.single_line reason
  in
  (* This TUI's own log: what it did and what it was told, oldest first so the
     newest event is last. The log holds eleven events ([add_event]); a run of
     the same event folds into one with a ×N tail. First in the section, so
     the block starts on screen. [session_rows] is how many rows the frame
     can give it, and [session_block] spends them on whole events. *)
  let session_lines =
    match state.events with
    | [] -> [ say "    (아직 이벤트 없음)" "    (no events yet)" ]
    | events ->
      let block =
        session_block ~now:(Unix.gettimeofday ()) ~width:inner_width ?room:session_rows events in
      let rows = List.concat_map (fun entry -> entry.rows) block.kept in
      if block.earlier > 0 then
        Printf.sprintf (if ko then "    %s이전 %s건%s" else "    %s%s earlier%s")
          (Theme.recede ()) (Count.grouped block.earlier) Ansi.reset
        :: rows
      else rows
  in
  List.map clip
    ([ title (say "TUI 세션" "TUI session") ] @ session_lines
     @ [ ""; title (say "엔진 메모리" "Engine memory") ] @ gc_lines
     @ [ ""; title (say "스케줄러 지연 (서버 표본 구간)" "Scheduler lag (producer sample window)") ]
     @ scheduler_lines
     @ [ ""; title (say "전송" "Transport delivery") ] @ transport_lines @ [ feed_line ])

(* The one ladder every other surface reads a span on. This pane had its own
   -- a single unit with a tenth after it -- so "how long since" read "7.6s"
   and "1.5d" here while the Board, Fusion, Keepers and the chat rows read
   "7s" and "1d12h" of the same question. The tenth was precision nobody acts
   on, and the single unit loses the second figure at every step above
   minutes. [Masc_tui_message_layout.span_text] says why it is shaped the way
   it is; the two callers before this one were joined for the same reason. *)
let age_text = Layout.span_text

let render_section_resources ~cols (state : state) =
  let inner_width = max 20 (framed_inner_width cols) in
  let clip text = Layout.truncate_end inner_width text ^ Ansi.reset in
  (* A block of this page is headed like every detail section (RFC
     tui-one-screen-grammar §5.2, §7.3). *)
  let title text = "  " ^ Section.styled_heading ~rule_style:(Theme.recede ()) text in
  let now = Unix.gettimeofday () in
  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  (* The blocks after the first read the same snapshot. Without one they say
     why in a word; the first block carries the loader's sentence. *)
  let no_snapshot = "    " ^ field_missing_reading ~ko ~error:state.tasks_error in
  let task_lines = match state.task_flow with
    | None ->
      [ "    "
        ^ (match state.tasks_error with
           | None -> field_unread ~ko
           | Some error -> Terminal_text.single_line error) ]
    | Some flow ->
      let current = flow.Task_flow.current in
      let moment at =
        Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_minute ~now at
      in
      (* A count of the tasks in a status, which the Tasks screen names. *)
      let in_status (tag : Masc_domain.Task_status_tag.t) count =
        Masc_tui_task_document.status_tag_label ~ko tag ^ " " ^ Count.grouped count
      in
      let row parts = "    " ^ String.concat " · " parts in
      [ row
          [ say "새 작업 " "New tasks " ^ Count.grouped flow.recent.created
          ; in_status Done flow.recent.completed
          ; in_status Cancelled flow.recent.cancelled ]
      ; Printf.sprintf (if ko then "    구간: %s ~ %s" else "    Window: %s to %s")
          (moment flow.window_started_at) (moment flow.observed_at)
      ; say "    지금 열린 작업 " "    Current open "
        ^ Count.grouped (Task_flow.open_count current) ^ ": "
        ^ String.concat " · "
            [ in_status Todo current.todo
            ; in_status Claimed current.claimed
            ; in_status In_progress current.in_progress
            ; in_status Awaiting_verification current.awaiting_verification ]
      ; row
          [ say "백로그 전체 " "Retained total " ^ Count.grouped (Task_flow.total_count current)
          ; in_status Done current.completed
          ; in_status Cancelled current.cancelled
          ; Printf.sprintf (if ko then "스냅샷 %s 전" else "snapshot %s ago")
              (Masc_tui_value.Ongoing.since ~now flow.observed_at) ]
      ; say "    가장 오래된 열린 작업: " "    Oldest open task registration: "
        ^ Option.fold ~none:(say "등록 시각을 아는 작업 없음" "none with a known timestamp")
            ~some:(fun at ->
              Printf.sprintf (if ko then "스냅샷 %s 전 등록" else "%s before this snapshot")
                (age_text (flow.observed_at -. at)))
            flow.oldest_open_created_at
      ; say "    완료는 작업 결과이고, 도구 호출과 턴 종료는 활동입니다."
          "    Done is a task outcome; tool calls and turn endings are activity." ]
      @ (if flow.unparseable_timestamps = 0 then [] else
           [ Printf.sprintf
               (if ko then "    구간 집계에서 뺀 잘못된 시각 %s개"
                else "    %s invalid timestamps excluded from time-window counts")
               (Count.grouped flow.unparseable_timestamps) ])
      @ (match state.tasks_error with None -> [] | Some error ->
           [ say "    스냅샷 경고: " "    Snapshot warning: " ^ Terminal_text.single_line error ])
  in
  (* One row per assignee, longest queue first. The list is capped so the two
     blocks below it stay on screen; the tail is reported as a count rather
     than dropped silently. The columns are fitted by cells: Printf pads by
     bytes, so a Korean head or name pulled every column after it left. *)
  let assignee_rows_shown = 10 in
  let assignee_row name done_count open_count lead =
    let count text = " " ^ Layout.pad_left text 6 in
    "    " ^ Layout.fit_width name 26 ^ count done_count ^ count open_count ^ "  " ^ lead
  in
  let assignee_lines = match state.task_flow with
    | None -> [ no_snapshot ]
    | Some flow ->
      (match flow.Task_flow.by_assignee with
       | [] -> [ say "    담당자가 있는 작업이 없습니다." "    No retained task carries an assignee." ]
       | rows ->
         let head = List.filteri (fun index _ -> index < assignee_rows_shown) rows in
         let body =
           List.map
             (fun (row : Task_flow.assignee_flow) ->
               assignee_row row.af_assignee (Count.grouped row.af_done)
                 (Count.grouped row.af_open)
                 (match row.af_median_lead_hours with
                  | None -> Masc_tui_theme.Glyph.no_value
                  | Some hours -> age_text (hours *. 3600.)))
             head
         in
         let omitted = List.length rows - List.length head in
         [ say "    키퍼 이름과 에이전트 이름은 합치지 않고 따로 적습니다."
             "    A keeper name and an agent name stay separate rows; nothing is merged."
         ; assignee_row (say "담당자" "assignee") (say "완료" "done") (say "열림" "open")
             (say "소요 중앙값" "median lead") ]
         @ body
         @ (if omitted <= 0 then []
            else
              [ "    " ^ Count.more ~ko omitted ]))
  in
  let day_label at = Masc_tui_value.Utc_day.month_day (Masc_tui_value.Utc_day.of_moment at) in
  let daily_title = match state.task_flow with
    | Some flow when flow.Task_flow.daily <> [] ->
      let first = List.hd flow.Task_flow.daily in
      let last = List.fold_left (fun _ day -> day) first flow.Task_flow.daily in
      Printf.sprintf
        (if ko then "일별 작업 흐름 · %s ~ %s UTC" else "Daily task flow · %s to %s UTC")
        (day_label first.Task_flow.d_start) (day_label last.Task_flow.d_start)
    | Some _ | None ->
      Printf.sprintf
        (if ko then "일별 작업 흐름 · UTC 기준 %d일간" else "Daily task flow · %d UTC days")
        Task_flow.daily_days
  in
  (* Days run across rather than down: the question is the shape of the trend,
     and one line per day pushes every other block off the section. A day's
     column is its widest figure and a space, so a day of a thousand tasks
     does not run into the next one, and does not widen the quiet days and
     push the latest off a narrow pane. *)
  let daily_lines = match state.task_flow with
    | None -> [ no_snapshot ]
    | Some flow ->
      let rows =
        [ say "날짜" "day", (fun (day : Task_flow.day) ->
              Masc_tui_value.Utc_day.day_of_month (Masc_tui_value.Utc_day.of_moment day.d_start))
        ; say "새 작업" "created", (fun (day : Task_flow.day) -> day.d_created)
        ; say "완료" "completed", (fun (day : Task_flow.day) -> day.d_completed)
        ; say "취소" "cancelled", (fun (day : Task_flow.day) -> day.d_cancelled) ]
      in
      let columns =
        List.map
          (fun day ->
            ( day
            , List.fold_left
                (fun width (_, pick) -> max width (1 + String.length (Count.grouped (pick day))))
                3 rows ))
          flow.Task_flow.daily
      in
      List.map
        (fun (label, pick) ->
          "    " ^ Layout.fit_width label 10
          ^ String.concat ""
              (List.map
                 (fun (day, width) -> Layout.pad_left (Count.grouped (pick day)) width)
                 columns))
        rows
      @ (match flow.Task_flow.daily with
         | [] -> []
         | (first : Task_flow.day) :: rest ->
           (* A day that completed nothing is the baseline, not a gap
              (RFC tui-one-screen-grammar 5.6). *)
           let samples =
             List.map (fun (day : Task_flow.day) -> Braille.of_count day.d_completed)
               (first :: rest)
           in
           let maximum = Braille.graph_maximum samples in
           let axis = Count.grouped maximum in
           let width = Layout.display_width axis + 1 + ((List.length samples + 1) / 2) in
           let spark =
             match
               Braille.braille_graph
                 ~tint:(Theme.series_tint Masc_tui_theme.Completion)
                 ~width ~rows:1 ~axis ~maximum samples
             with
             | Braille.Drawn rows -> String.concat "" rows
             | Braille.Too_narrow ->
               Count.grouped
                 (List.fold_left (fun _ (day : Task_flow.day) -> day.d_completed)
                    first.d_completed rest)
             | Braille.Never_read -> Unknown.(glyph Unread)
           in
           [ "    " ^ Layout.fit_width (say "완료 추세" "done trend") 10 ^ " " ^ spark ])
  in
  let turn_lines = match state.keeper_turns_observed_at, state.keeper_turns_error with
    | _, Some error ->
      [ "    " ^ Terminal_text.single_line
          (request_failure_text ~ko ~request:Kept_request.Turn_observation_read error)
      ; say "    이전 행은 지금 실행 중인 턴으로 세지 않습니다."
          "    Previous rows are not counted as current running turns." ]
    | None, None -> [ "    " ^ field_unread ~ko ]
    | Some observed_at, None ->
      (* The age below is drawn from the observation time, which every
         successful turns answer moves (RFC tui-one-screen-grammar §8). *)
      note_turn_observation_age_drawn ();
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
      [ Printf.sprintf
          (if ko then "    실행 중 %s · 대기 중 %s · 확인 불가 %s · %s 전 조회"
           else "    %s running · %s idle · %s unavailable · observed %s ago")
          (Count.grouped (List.length running)) (Count.grouped idle)
          (Count.grouped unavailable) (Masc_tui_value.Ongoing.since ~now observed_at)
      ; say "    턴 시간은 키퍼가 알린 시작 시각부터 잽니다."
          "    Turn age = since owner-reported start." ]
      @ List.map
          (fun (name, lane, started_at_unix) ->
              Printf.sprintf
                (if ko then "    %s  턴 %8s  레인 %s" else "    %s  turn %8s  lane %s")
                (Layout.fit_width name 18)
                (Masc_tui_value.Ongoing.since ~now started_at_unix)
                (Masc_tui_answering.lane_word ~ko lane))
          running
  in
  (* A failed read is the loader's own sentence, as the Keepers header draws
     it. It read the words this block says before the first read, so a fleet
     the TUI could not read looked like one it had not asked for yet
     (#38499). *)
  let readiness text = say "    실행 준비: " "    Execution readiness: " ^ text in
  let safety_lines = match fleet_stream_view state with
    | Masc_tui_fleet_stream.Cannot_read failure ->
      [ readiness (Masc_tui_fleet_line.failure_text ~ko failure) ]
    | Masc_tui_fleet_stream.Awaiting_first_reading -> [ readiness (field_unread ~ko) ]
    | Masc_tui_fleet_stream.Unreachable { since } ->
      [ readiness (Masc_tui_fleet_line.unreachable_text ~ko ~now ~since) ]
    | Masc_tui_fleet_stream.Unavailable { degradation; disconnected_since } ->
      [ readiness
          (Masc_tui_fleet_line.unavailable_text ~ko ~now ~degradation ~disconnected_since) ]
    | Masc_tui_fleet_stream.Reading { reading = { fleet = safety; _ }; trouble } ->
      Printf.sprintf
        (if ko then "    실행 가능 %s · 목표 %s · 부족 %s · 실패 %s · 일시정지 %s"
         else "    Executable %s · target %s · shortfall %s · failing %s · paused %s")
        (Count.grouped safety.fs_executable_count)
        (Count.grouped safety.fs_target_reaction_capacity)
        (Count.grouped safety.fs_reaction_capacity_shortfall)
        (Count.grouped safety.fs_failing_count) (Count.grouped safety.fs_paused_count)
      :: (trouble
          |> Option.map (fun trouble -> "    " ^ Masc_tui_fleet_line.trouble_text ~ko ~now trouble)
          |> Option.to_list)
  in
  List.map clip
    ([ title (say "작업 결과 · 스냅샷 전 24시간" "Retained task outcomes · 24-hour snapshot window") ]
     @ task_lines
     @ [ ""
       ; title
           (say "담당자별 작업 · 소요는 등록부터 완료까지"
              "Work per assignee · lead time is created to completed") ]
     @ assignee_lines
     @ [ ""; title daily_title ] @ daily_lines
     @ [ ""; title (say "현재 턴" "Current owner turns") ] @ turn_lines
     @ [ ""; title (say "실행 준비 (fleet 스트림)" "Execution readiness (fleet stream)") ]
     @ safety_lines)

let render_section_tools ~cols (state : state) : string list =
  (* Section 3: Memory & Gate Safety *)
  let inner_width = max 20 (framed_inner_width cols) in
  let clip line = Layout.truncate_end inner_width line in
  let bar_w = min 60 (max 20 (inner_width - 8)) in

  let ko = state.ui_language = Lang_ko in
  let say korean english = if ko then korean else english in
  let title_mem =
    "  " ^ Section.styled_heading ~rule_style:(Theme.recede ())
      (say "Memory OS 사실 저장소" "Memory OS knowledge base & fact store")
  in
  (* The same four states the Gate rows below draw. This read "not loaded --
     visit Memory surface to fetch" whatever had happened: arriving here
     already asks for memory health, the same request the Memory surface
     makes, so the advice sent the reader to repeat it, and a read that had
     failed read as one never made. *)
  let memory =
    observe_source ~observed:(Option.is_some state.memory_health)
      ~error:(memory_health_error_text state) state.memory_health
  in
  let memory_status =
    say "    기억 상태: " "    Memory health: "
    ^ observation_detail_with ~ko ~current:(fun _ -> "") memory
  in
  let memory_rows =
    match state.memory_health with
    | None -> []
    | Some mhs ->
        let total_facts = mhs.mhs_total_facts in
        (* The ordinary snapshots' size, named as the Memory screen names it. *)
        let header =
          Printf.sprintf
            (if ko then "    일반 사실 %s · 출처 사실 %s · 일반 저장량 %s tok"
             else "    Ordinary facts %s · source facts %s · ordinary stored %s tok")
            (Count.grouped total_facts)
            (Count.grouped mhs.mhs_total_source_facts)
            (Masc_tui_token_scale.format_estimate Masc_tui_token_scale.fleet
               (List.fold_left (fun acc (k : Masc.Tui_decode_memory_health.memory_keeper_health) -> acc + k.mkh_snapshot_bytes) 0 mhs.mhs_keepers))
        in
        let rows =
          if mhs.mhs_keepers = [] then
            [ say "    (기억 구역이 있는 등록 키퍼 없음)"
                "    (no registered keepers with memory partitions)" ]
          else
            List.map
              (fun (k : Masc.Tui_decode_memory_health.memory_keeper_health) ->
                let bar =
                  Chart.meter ~width:16 ~value:k.mkh_facts
                    ~max_value:(max 1 total_facts)
                    ~scale:(Chart.Series { paint = Theme.paint (); series = Masc_tui_theme.Memory })
                    ~track_style:(Theme.recede ()) ~reset:Ansi.reset ()
                in
                Printf.sprintf
                  (if ko then "    %s  사실 %s  %s  %s tok%s" else "    %s  %s facts  %s  %s tok%s")
                  (Layout.fit_width
                     (Terminal_text.single_line k.mkh_keeper_id)
                     16)
                  (Layout.pad_left (Count.grouped k.mkh_facts) 6)
                  bar
                  (Masc_tui_token_scale.format_estimate
                     Masc_tui_token_scale.fleet k.mkh_snapshot_bytes)
                  Ansi.reset)
              mhs.mhs_keepers
        in
        header :: rows
  in
  let mem_lines =
    match memory with
    | Current _ -> memory_rows
    | Stale _ -> memory_status :: memory_rows
    | Read_failed _ | Unavailable _ | Not_observed -> [ memory_status ]
  in

  let title_gate =
    "  " ^ Section.styled_heading ~rule_style:(Theme.recede ())
      (say "Gate 승인과 보안 설정" "Gate governance & security stance")
  in
  let gate = gate_observation state in
  let held = held_observation state in
  let rules =
    observe_source ~observed:state.gate_snapshot_observed ~error:state.gate_error
      ?unavailable:state.gate_rules_unavailable state.gate_rules in
  let yolo =
    observe_source ~observed:state.keeper_tool_modes_observed
      ~error:state.keeper_tool_modes_error state.keeper_yolo_names in
  let module Tool_map = Map.Make (String) in
  let counts =
    let add_tool acc tool =
      let current = Option.value (Tool_map.find_opt tool acc) ~default:0 in
      Tool_map.add tool (current + 1) acc
    in
    let acc =
      match current_value gate with
      | None -> Tool_map.empty
      | Some gps ->
        List.fold_left
          (fun acc (gp : Decode.gate_pending) ->
            add_tool acc (Terminal_text.single_line gp.gp_display_tool))
          Tool_map.empty
          gps
    in
    match current_value held with
    | None -> acc
    | Some ktas ->
      List.fold_left
        (fun acc (kta : Decode.keeper_tool_approval) ->
          add_tool acc (Terminal_text.single_line kta.kta_tool))
        acc
        ktas
  in

  let gate_summary =
    [ say "    Gate 승인 대기: " "    Pending Gate Calls: " ^ observation_detail ~ko gate
    ; say "    보류된 호출: " "    Held Tool Approvals: " ^ observation_detail ~ko held
    ; say "    항상 허용 규칙: " "    Standing Rules: " ^ observation_detail ~ko rules
    ; say "    YOLO 키퍼: " "    YOLO Keepers: " ^ observation_detail ~ko yolo ]
  in
  let yolo_line =
    match yolo with
    | Current (_ :: _ as names) ->
      [ say "    YOLO 실행: " "    YOLO Execution: "
        ^ String.concat " \xc2\xb7 " (List.map Terminal_text.single_line names) ]
    | Current [] | Not_observed | Read_failed _ | Unavailable _ | Stale _ -> []
  in

  let tool_bars =
    if Tool_map.is_empty counts then
      (match gate, held with
       | Current [], Current [] ->
         [ say "    (Gate 승인 대기와 보류된 호출 없음)"
             "    (no active pending gate operations or held approval requests)" ]
       | (Current [], Current (_::_))
       | (Current [], (Not_observed | (Read_failed _ | (Unavailable _ | Stale _))))
       | (Current (_::_), _) | ((Not_observed | (Read_failed _ | (Unavailable _ | Stale _))), _) ->
         [ say "    도구별 대기 수를 다 읽지 못해 비었다고 보지 않습니다."
             "    Pending tool totals unavailable; no empty queue inferred" ])
    else
      let items =
        Tool_map.fold
          (fun name count acc ->
            { Chart.name; count; style = Masc_tui_theme.Warn } :: acc)
          counts []
        |> List.sort (fun (a : Chart.bar_item) (b : Chart.bar_item) ->
               let c = Int.compare b.count a.count in
               if c <> 0 then c else String.compare a.name b.name)
      in
      let scope = match gate, held with
        | Current _, Current _ -> []
        | (Current _, (Not_observed | (Read_failed _ | (Unavailable _ | Stale _))))
        | ((Not_observed | (Read_failed _ | (Unavailable _ | Stale _))), _) ->
          [ say "    도구 분포: 읽은 대기열만 (일부 관측)"
              "    Tool distribution: observed queues only (partial coverage)" ] in
      scope @ (Chart.distribution_bars ~width:bar_w items
        |> List.map (fun l -> "    " ^ l))
  in

  [ clip title_mem ]
  @ List.map clip mem_lines
  @ [ ""
    ; clip title_gate
    ]
  @ List.map clip (gate_summary @ yolo_line)
  @ [ "" ]
  @ List.map clip tool_bars

let rebase_scroll_for_cards ~scroll ~previous_cards ~current_cards =
  match previous_cards with
  | None -> scroll
  | Some previous_cards ->
      if scroll = 0 || scroll = clamped_scroll_end then scroll
      else Masc_tui_scroll.step_uncounted ~delta:(current_cards - previous_cards) scroll

let render_metrics_body ~cols ~budget ~suffix_lines (state : state)
    ~(report_scroll : int -> int -> int -> unit)
    ~(hand_position : Masc_tui_value.Position.t -> unit)
    ~(push : string -> unit)
    ~(push_styled : style:string -> string -> unit)
    ~push_selected:_
    ~(push_divider : unit -> unit)
    ~(push_empty : unit -> unit) : unit =
  let ko = state.ui_language = Lang_ko in
  let kpis = calculate_kpis state in
  let pulse = pulse_line ~cols state kpis in
  push pulse;
  let pills = section_pills_line ~ko ~cols ~active:state.metrics_section in
  push pills;
  push_divider ();
  let card_lines = render_kpi_cards ~cols state kpis in
  (* On a short, wide terminal the cards alone can consume the body. Keep
     them scrollable in that case so the section and status remain reachable. *)
  let pinned_cards, scroll_cards =
    if budget <= 4 + List.length card_lines then [], card_lines
    else card_lines, [] in
  List.iter push pinned_cards;
  if suffix_lines = [] then push_divider ()
  else push_styled ~style:(Theme.recede ()) (metrics_status_at_end ~ko);
  let fixed_rows = 1 + 1 + 1 + List.length pinned_cards + 1 in
  let room = max 0 (budget - fixed_rows) in
  let section_lines =
    match state.metrics_section with
    | Section_fleet ->
      (* The block's title takes one row and the scroll hint under the
         section may take another. Use the space before cards move into the
         scroll, so the card transition does not also expand the log. *)
      let room_with_pinned_cards = max 0 (budget - 4 - List.length card_lines) in
      render_section_fleet ~session_rows:(max 1 (room_with_pinned_cards - 2)) ~cols state
    | Section_resources -> render_section_resources ~cols state
    | Section_tools -> render_section_tools ~cols state
  in
  let section_lines = scroll_cards @ section_lines @ suffix_lines in
  let total_lines = List.length section_lines in
  let available = room in
  let max_scroll = max 0 (total_lines - available) in
  let card_rows = List.length scroll_cards in
  let scroll =
    rebase_scroll_for_cards ~scroll:state.metrics_scroll
      ~previous_cards:state.metrics_scroll_card_rows ~current_cards:card_rows
    |> min max_scroll |> max 0 in
  (* The row this frame could actually start at, handed back so the next
     keypress steps from it rather than from wherever the last one left the
     stored value. *)
  report_scroll scroll available card_rows;
  (* Where the window stands is the title row's; the keys that move it are
     the footer's. *)
  Option.iter hand_position
    (Masc_tui_value.Position.window ~first:scroll ~shown:available ~total:total_lines);
  let section_lines_window =
    Rows.of_list ~first:scroll ~height:available section_lines
  in
  for i = 0 to available - 1 do
    let idx = i + scroll in
    match Rows.at section_lines_window idx with
    | Some line -> push line
    | None -> push_empty ()
  done
