module Ansi = Masc_tui_ansi.Ansi
module Card = Masc_tui_card
module Chart = Masc_tui_chart
module Layout = Masc_tui_message_layout
module Theme = Masc_tui_ansi.Theme
module Palette = Masc_tui_theme
module Value = Masc_tui_value

type plan =
  | Cards_only
  | With_bands of {
      telemetry_rows : int;
      keeper_rows : int;
      card_rows : int;
    }

let min_cols = 88
let min_rows = 18
let min_card_rows = 8
let telemetry_fixed_rows = 4

let plan ~available ~cols ~keeper_count =
  if cols < min_cols || available < min_rows then Cards_only
  else
    let telemetry_rows = telemetry_fixed_rows in
    let raw_keeper_rows =
      if keeper_count <= 0 then 0
      else
        let desired = min 6 (keeper_count + 2) in
        let max_share = max 4 ((available - telemetry_rows) / 3) in
        min desired max_share
    in
    let keeper_rows =
      if available - telemetry_rows - raw_keeper_rows >= min_card_rows then
        raw_keeper_rows
      else 0
    in
    let card_rows = available - telemetry_rows - keeper_rows in
    if card_rows < min_card_rows then Cards_only
    else With_bands { telemetry_rows; keeper_rows; card_rows }

type telemetry_snapshot = {
  fleet_running : int;
  fleet_bootable : int;
  capacity_avail : int;
  capacity_target : int;
  capacity_shortfall : int;
  fleet_status : Card.status option;
  heap_live_words : int option;
  heap_total_words : int option;
  heap_live_text : string option;
  heap_total_text : string option;
  sched_p95_ms : float option;
  sched_stalls : int option;
  tool_calls_summary : string option;
}

type keeper_entry = {
  name : string;
  mark : string;
  mark_tone : string;
  state_label : string;
  activity_summary : string;
  detail : string;
  needs_attention : bool;
}

let card_style () =
  { Card.border = Theme.recede ()
  ; focused_border = Theme.border_focus ()
  ; title_style = Ansi.bold
  ; reset = Ansi.reset
  }

let pad_cell ~width text =
  let fitted = Layout.fit_width text width in
  let used = Layout.display_width fitted in
  if used >= width then fitted
  else fitted ^ String.make (width - used) ' '

let join_columns ~cells left right =
  let gap = 2 in
  if cells < 48 then Layout.fit_width left cells
  else
    let left_w = (cells - gap) / 2 in
    let right_w = cells - gap - left_w in
    pad_cell ~width:left_w left ^ String.make gap ' ' ^ Layout.fit_width right right_w

let render_telemetry ~ko ~width ~height snap =
  let say ko_s en_s = if ko then ko_s else en_s in
  let count =
    if snap.fleet_running > 0 || snap.fleet_bootable > 0 then
      Some (Card.Whole snap.fleet_running)
    else None
  in
  let edge =
    { Card.name = say "플릿 · 엔진" "Fleet · Engine"
    ; key = None
    ; status = snap.fleet_status
    ; count
    ; focus = Card.Unfocused
    ; border_accent = Some (Theme.panel_border Palette.Panel_fleet)
    ; footer_keys =
        [ { Card.key = "m"; label = say "사용량" "Usage" } ]
    }
  in
  let body ~cells =
    let col_w = if cells >= 48 then (cells - 2) / 2 else cells in
    let right_w = if cells >= 48 then cells - 2 - col_w else cells in
    let fleet_meter =
      if snap.fleet_bootable > 0 then
        Chart.meter ~width:col_w ~value:snap.fleet_running
          ~max_value:(max 1 snap.fleet_bootable)
          ~label:(say "실행" "Run") ~label_style:(Theme.recede ())
          ~suffix:(Printf.sprintf "%d/%d" snap.fleet_running snap.fleet_bootable)
          ~scale:(Chart.Series { paint = Theme.paint (); series = Palette.Capacity })
          ~track_style:(Theme.recede ()) ~reset:Ansi.reset ()
      else
        Theme.recede ()
        ^ Layout.fit_width (say "실행 —" "Run —") col_w
        ^ Ansi.reset
    in
    let capacity_meter =
      if snap.capacity_target > 0 then
        let suffix =
          if snap.capacity_shortfall > 0 then
            Printf.sprintf "%d/%d -%d" snap.capacity_avail snap.capacity_target
              snap.capacity_shortfall
          else Printf.sprintf "%d/%d" snap.capacity_avail snap.capacity_target
        in
        Chart.meter ~width:col_w ~value:snap.capacity_avail
          ~max_value:(max 1 snap.capacity_target)
          ~label:(say "여력" "Cap") ~label_style:(Theme.recede ())
          ~suffix
          ~scale:(Chart.Series { paint = Theme.paint (); series = Palette.Capacity })
          ?suffix_style:
            (if snap.capacity_shortfall > 0 then Some (Theme.warn ()) else None)
          ~track_style:(Theme.recede ()) ~reset:Ansi.reset ()
      else
        Theme.recede ()
        ^ Layout.fit_width (say "여력 —" "Cap —") col_w
        ^ Ansi.reset
    in
    let heap_line =
      match
        snap.heap_live_words, snap.heap_total_words, snap.heap_live_text, snap.heap_total_text
      with
      | Some live, Some total, Some live_s, Some total_s when total > 0 ->
          Chart.meter ~width:right_w ~value:live ~max_value:(max 1 total)
            ~label:(say "힙" "Heap") ~label_style:(Theme.recede ())
            ~suffix:(Printf.sprintf "%s/%s" live_s total_s)
            ~scale:(Chart.Series { paint = Theme.paint (); series = Palette.Memory })
            ~track_style:(Theme.recede ()) ~reset:Ansi.reset ()
      | _ ->
          Theme.recede ()
          ^ Layout.fit_width (say "힙 —" "Heap —") right_w
          ^ Ansi.reset
    in
    let sched_and_tools =
      let sched_part =
        match snap.sched_p95_ms, snap.sched_stalls with
        | Some p95, Some stalls when stalls > 0 ->
            Theme.recede () ^ "p95 " ^ Ansi.reset
            ^ Theme.warn ()
            ^ Printf.sprintf (if ko then "%.2fms · 정체 %d" else "%.2fms · %d stalls")
                p95 stalls
            ^ Ansi.reset
        | Some p95, _ ->
            let p95_style =
              if p95 >= 100. then Theme.warn ()
              else Theme.series_tint Palette.Latency 1.0
            in
            Theme.recede () ^ "p95 " ^ Ansi.reset
            ^ p95_style ^ Printf.sprintf "%.2fms" p95 ^ Ansi.reset
        | None, _ ->
            Theme.recede () ^ "p95 " ^ Value.Unknown.(glyph Unread) ^ Ansi.reset
      in
      match snap.tool_calls_summary with
      | Some summary when not (String.equal summary "") ->
          sched_part ^ Theme.recede () ^ " · " ^ Ansi.reset ^ summary
      | _ -> sched_part
    in
    [ join_columns ~cells fleet_meter heap_line
    ; join_columns ~cells capacity_meter sched_and_tools
    ]
  in
  Card.render ~ko ~style:(card_style ()) ~width ~height { Card.edge; body }

let render_keeper_row ~cells entry =
  let mark = entry.mark_tone ^ entry.mark ^ Ansi.reset in
  let name_w = min 18 (max 10 (cells / 4)) in
  let state_w = 10 in
  let activity_w = 12 in
  let name_cell =
    let fitted = pad_cell ~width:name_w entry.name in
    if entry.needs_attention then Ansi.bold ^ fitted ^ Ansi.reset else fitted
  in
  let state_cell =
    let tone = if entry.needs_attention then Theme.warn () else Theme.recede () in
    tone ^ pad_cell ~width:state_w entry.state_label ^ Ansi.reset
  in
  let activity_cell =
    let text = String.trim entry.activity_summary in
    if String.equal text "" || String.equal text Palette.Glyph.no_value then
      Theme.recede () ^ pad_cell ~width:activity_w Palette.Glyph.no_value ^ Ansi.reset
    else
      pad_cell ~width:activity_w text
  in
  let prefix = mark ^ " " ^ name_cell ^ "  " ^ state_cell ^ "  " ^ activity_cell in
  let prefix_cells = Layout.display_width prefix in
  let detail_room = cells - prefix_cells - 2 in
  if detail_room <= 3 || String.equal entry.detail "" then
    Layout.fit_width prefix cells
  else
    prefix ^ "  " ^ Theme.recede () ^ Layout.fit_width entry.detail detail_room ^ Ansi.reset

let render_keepers ~ko ~width ~height ~total_keepers entries =
  let say ko_s en_s = if ko then ko_s else en_s in
  let edge =
    { Card.name = say "키퍼" "Keepers"
    ; key = None
    ; status = None
    ; count = Some (Card.Whole total_keepers)
    ; focus = Card.Unfocused
    ; border_accent = Some (Theme.panel_border Palette.Panel_usage)
    ; footer_keys =
        [ { Card.key = "Left"; label = say "키퍼" "Keepers" } ]
    }
  in
  let body ~cells =
    match entries with
    | [] -> [ Theme.recede () ^ say "등록된 키퍼 없음" "No keepers registered" ^ Ansi.reset ]
    | rows -> List.map (render_keeper_row ~cells) rows
  in
  Card.render ~ko ~style:(card_style ()) ~width ~height { Card.edge; body }
