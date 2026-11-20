module Series = Masc.Tui_decode_tool_series
module Braille = Masc_tui_braille
module Ansi = Masc_tui_ansi.Ansi
module Theme = Masc_tui_ansi.Theme
module Layout = Masc_tui_message_layout
module Table = Masc_tui_table

type window =
  | Last_day
  | Last_week
  | Last_fortnight

let window_of_days = function
  | 1 -> Some Last_day
  | 7 -> Some Last_week
  | 14 -> Some Last_fortnight
  | _ -> None

let days = function
  | Last_day -> 1
  | Last_week -> 7
  | Last_fortnight -> 14

let bucket_count = function
  | Last_day -> 24
  | Last_week -> 7
  | Last_fortnight -> 14

let width = function
  | Last_day -> Series.Series_hour
  | Last_week | Last_fortnight -> Series.Series_day

let hours_per_bucket = function
  | Series.Series_hour -> 1
  | Series.Series_day -> 24

let since_hours window = bucket_count window * hours_per_bucket (width window)

let reread_s = 60.0

type t = {
  window : window;
  series : Series.tool_series;
}

let rec drop count = function
  | rest when count <= 0 -> rest
  | [] -> []
  | _ :: rest -> drop (count - 1) rest

let of_series window (series : Series.tool_series) =
  let wanted = bucket_count window in
  let held = List.length series.Series.tsr_buckets in
  if series.Series.tsr_width <> width window then
    Error "series answered in the other bucket width than the window draws"
  else if series.Series.tsr_utc_offset_min <> 0 then
    Error
      (Printf.sprintf "series edges follow UTC%+d minutes, not UTC"
         series.Series.tsr_utc_offset_min)
  else if held < wanted then
    Error (Printf.sprintf "series holds %d buckets, the window draws %d" held wanted)
  else
    Ok
      { window;
        series =
          { series with
            Series.tsr_buckets = drop (held - wanted) series.Series.tsr_buckets } }

(* What a bucket in which no call ran draws. The same mark stands for "no call"
   in every row of the chart: a bucket without a call has no failed call and no
   latency, which is not the same as zero of either. *)
let no_call_mark = "\xc2\xb7"

(* Braille LED columns on the graph rules of RFC tui-one-screen-grammar
   section 5.6, four dots to a text row: a reported zero is the baseline
   [⣀], and a value above zero stands at least one level above it, so one
   failed call among thirty is told apart from none by its shape and not by
   its colour alone. [⣀] means zero here as on every other graph. *)
let column_dots = 4

(* How many text rows a chart row takes when the section has the room: three
   rows give twelve vertical dot levels and three btop gradient stops. *)
let tall_rows = 3

let p95_sample (active : Series.tool_series_calls) =
  Braille.of_milliseconds active.Series.tsc_p95_ms

let calls_sample (active : Series.tool_series_calls) =
  Braille.of_count active.Series.tsc_calls

let failures_sample (active : Series.tool_series_calls) =
  Braille.of_count active.Series.tsc_failures

(* The slowest p95 across the buckets, as reported, for the row's note. *)
let worst_p95_ms buckets =
  List.fold_left
    (fun worst (bucket : Series.tool_series_bucket) ->
      match bucket.Series.tsb_activity with
      | Series.Series_idle -> worst
      | Series.Series_active active -> Float.max worst active.Series.tsc_p95_ms)
    0.0 buckets

let every_call_failed (calls : Series.tool_series_calls) =
  calls.Series.tsc_failures = calls.Series.tsc_calls

let grouped_digits = Masc_tui_value.Count.grouped

(* A p95 is how long calls took, so it reads on the finished-length ladder of
   RFC tui-one-screen-grammar 6.2 that the Lanes table and approvals already
   use: [243ms], [29.2s], [6m55s], with no space before the unit. A negative
   or non-numeric p95 is a reading that failed and draws the failed mark. *)
let milliseconds_text ms =
  Option.value
    ~default:(Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Read_failed)
    (Masc_tui_message_layout.elapsed_text (ms /. 1000.0))

let percent_text ~failures ~calls =
  if failures = 0 then "0%"
  else Printf.sprintf "%.1f%%" (100.0 *. float_of_int failures /. float_of_int calls)

let unit_suffix = function
  | Series.Series_hour -> "/h"
  | Series.Series_day -> "/d"

(* An hour bucket starts at a moment, and reads in the operator's zone like
   every other moment, the heading's "as of" among them (RFC
   tui-one-screen-grammar §6.1). A day bucket is a UTC day the server chose:
   it starts at 09:00 in Seoul, so it is no local day and says UTC. The card
   drew both in UTC under an "as of" in local time, nine hours apart. *)
let time_text series_width start =
  match series_width with
  | Series.Series_hour ->
      Masc_tui_value.Instant.cell_text Masc_tui_value.Instant.To_minute
        ~now:(Unix.gettimeofday ()) start
  | Series.Series_day -> Masc_tui_value.Utc_day.month_day (Masc_tui_value.Utc_day.of_moment start)

let time_header ~ko = function
  | Series.Series_hour -> if ko then "시각" else "HOUR"
  | Series.Series_day -> if ko then "날짜(UTC)" else "DAY (UTC)"

let totals buckets =
  List.fold_left
    (fun (calls, failures, deferred) (bucket : Series.tool_series_bucket) ->
      match bucket.Series.tsb_activity with
      | Series.Series_idle -> (calls, failures, deferred)
      | Series.Series_active active ->
          ( calls + active.Series.tsc_calls,
            failures + active.Series.tsc_failures,
            deferred + active.Series.tsc_deferred ))
    (0, 0, 0) buckets

let margin = " "
let label_cells = 7
let note_gap = 2
let widest_load_bar = 24
let narrowest_load_bar = 6

let span_name ~ko = function
  | Last_day -> if ko then "최근 24시간" else "last 24 hours"
  | Last_week -> if ko then "최근 7일(UTC)" else "7 UTC days"
  | Last_fortnight -> if ko then "최근 14일(UTC)" else "14 UTC days"

let span_text ~ko window =
  span_name ~ko window
  ^
  match width window with
  | Series.Series_hour -> if ko then " · 시간별" else " · per hour"
  | Series.Series_day -> if ko then " · 일별(UTC)" else " · per UTC day"

(* The first of the wordings that fits [cells]; the last one is cut to [cells]
   when it does not fit either. *)
let rec first_within ~cells wording rest =
  match rest with
  | [] -> Layout.truncate_end cells wording
  | next :: later ->
      if Layout.display_width wording <= cells then wording
      else first_within ~cells next later

(* The longest wording that fits goes first. The time the numbers are from
   stays in every wording: the answer can be a read behind the store, and this
   time is what says by how much. *)
let heading ~ko ~cells t =
  let stamp =
    Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_minute ~now:(Unix.gettimeofday ())
      t.series.Series.tsr_generated_at
  in
  let time = if ko then stamp ^ " 기준" else "as of " ^ stamp in
  let title = if ko then "도구 호출" else "Tool calls" in
  let full_title = Printf.sprintf "%s (%s)" title (span_text ~ko t.window) in
  let short_title = Printf.sprintf "%s (%s)" title (span_name ~ko t.window) in
  let rule_badge_fits =
    cells >= 28 && (cells - 1) / 3 >= Layout.display_width time
  in
  let rule_fits_label label =
    4 + Layout.display_width time + Layout.display_width label <= cells - 1
  in
  match
    if not rule_badge_fits then None
    else List.find_opt rule_fits_label [ full_title; short_title; title ]
  with
  | Some label -> Masc_tui_doc.section_rule ~width:cells ~indent:1 ~badge:time label
  | None ->
      first_within ~cells
        (Printf.sprintf " %s (%s) · %s" title (span_text ~ko t.window) time)
        [ Printf.sprintf " %s (%s) · %s" title (span_name ~ko t.window) time;
          Printf.sprintf " %s · %s" title time;
          " " ^ time ]

let note_lines ?(ko = false) ~days note =
  let span =
    match window_of_days days with
    | Some window -> span_text ~ko window
    | None ->
        if ko then Printf.sprintf "최근 %d일(UTC)" days
        else Printf.sprintf "%d UTC days" days
  in
  let title = if ko then "도구 호출" else "Tool calls" in
  [ Printf.sprintf " %s (%s) · %s" title span note ]

let wrap_style style text =
  if String.equal style "" then text else style ^ text ^ Ansi.reset

let totals_line ~ko ~calls ~failures ~deferred =
  let sep = wrap_style (Theme.recede ()) " · " in
  let fail_style =
    if failures > 0 && failures = calls then Theme.bad ()
    else if failures > 0 then Theme.warn ()
    else Theme.recede ()
  in
  let fail_part =
    let body =
      if ko then
        Printf.sprintf "실패 %s건 (%s)" (grouped_digits failures)
          (percent_text ~failures ~calls)
      else
        Printf.sprintf "%s failed (%s)" (grouped_digits failures)
          (percent_text ~failures ~calls)
    in
    wrap_style fail_style body
  in
  let deferred_part =
    if deferred = 0 then ""
    else
      let body =
        if ko then Printf.sprintf "보류 %s건" (grouped_digits deferred)
        else Printf.sprintf "%s deferred" (grouped_digits deferred)
      in
      sep ^ wrap_style (Theme.warn ()) body
  in
  let calls_part =
    if ko then Printf.sprintf " 호출 %s건" (grouped_digits calls)
    else Printf.sprintf " %s calls" (grouped_digits calls)
  in
  calls_part ^ sep ^ fail_part ^ deferred_part

let series_maximum ~sample buckets =
  Braille.graph_maximum
    (List.filter_map
       (fun (bucket : Series.tool_series_bucket) ->
         match bucket.Series.tsb_activity with
         | Series.Series_idle -> None
         | Series.Series_active active -> Some (sample active))
       buckets)

(* The oldest and the newest bucket named at the two ends of a rule. *)
let ruler ~span ~series_width buckets =
  match buckets, List.rev buckets with
  | (first : Series.tool_series_bucket) :: _, (last : Series.tool_series_bucket) :: _ ->
      let oldest = time_text series_width first.Series.tsb_start in
      let newest = time_text series_width last.Series.tsb_start in
      let labels = Layout.display_width oldest + Layout.display_width newest + 2 in
      if span < labels + 2 then []
      else
        [ margin
          ^ String.make label_cells ' '
          ^ Theme.recede ()
          ^ oldest ^ " "
          ^ String.concat "" (List.init (span - labels) (fun _ -> Ansi.box_h))
          ^ " " ^ newest ^ Ansi.reset ]
  | [], _ | _, [] -> []

(* Smooth interpolated btop-style Braille wave stretched continuously across
   [span] cells: consecutive active buckets are interpolated subcolumn by
   subcolumn, idle buckets keep [no_call_mark] on the base row only, and
   buckets where every call failed highlight in Alert red. *)
let draw_curve_rows ~tall ~span ~maximum ~sample ~tint buckets =
  let tall = max 1 tall in
  let dots = column_dots * tall in
  let arr = Array.of_list buckets in
  let count = Array.length arr in
  let level_opts =
    List.map
      (fun (bucket : Series.tool_series_bucket) ->
        match bucket.Series.tsb_activity with
        | Series.Series_idle -> None
        | Series.Series_active active ->
            Some (Braille.braille_level ~dots ~maximum (sample active)))
      buckets
  in
  let pairs = Array.of_list (Braille.interpolate_pairs ~cells:span level_opts) in
  let bucket_at cell =
    if count <= 0 || span <= 0 then Series.Series_idle
    else arr.(min (count - 1) ((cell * count) / span)).Series.tsb_activity
  in
  List.init tall (fun row_idx ->
    let from_base = tall - 1 - row_idx in
    let base_row = from_base = 0 in
    let row_style =
      if tall = 1 then ""
      else tint (float_of_int from_base /. float_of_int (tall - 1))
    in
    let buf = Buffer.create (span * 8) in
    let open_style = ref "" in
    let emit_style style =
      if not (String.equal style !open_style) then begin
        Buffer.add_string buf (if String.equal style "" then Ansi.reset else style);
        open_style := style
      end
    in
    for c = 0 to span - 1 do
      let l, r = if c < Array.length pairs then pairs.(c) else (0, 0) in
      let rl = max 0 (min column_dots (l - (column_dots * from_base))) in
      let rr = max 0 (min column_dots (r - (column_dots * from_base))) in
      let activity = bucket_at c in
      let is_idle_empty =
        l = 0 && r = 0
        &&
        match activity with
        | Series.Series_idle -> true
        | Series.Series_active _ -> false
      in
      let is_all_failed =
        match activity with
        | Series.Series_active active -> every_call_failed active
        | Series.Series_idle -> false
      in
      if is_idle_empty then begin
        if base_row then begin
          emit_style (Theme.recede ());
          Buffer.add_string buf no_call_mark
        end else begin
          emit_style "";
          Buffer.add_char buf ' '
        end
      end else if rl = 0 && rr = 0 then begin
        emit_style "";
        Buffer.add_char buf ' '
      end else begin
        let style =
          if is_all_failed then Theme.bad ()
          else if tall = 1 then tint (Braille.value_share ~dots (max l r))
          else row_style
        in
        emit_style style;
        Buffer.add_string buf (Braille.braille_pair ~left:rl ~right:rr)
      end
    done;
    if not (String.equal !open_style "") then Buffer.add_string buf Ansi.reset;
    Buffer.contents buf)

let chart_lines ~ko ~tall ~cells t =
  let buckets = t.series.Series.tsr_buckets in
  let series_width = t.series.Series.tsr_width in
  let count = List.length buckets in
  let per = unit_suffix series_width in
  let calls_tint = Theme.series_tint Masc_tui_theme.Calls in
  let failed_tint = Theme.warm_tint () in
  let p95_tint = Theme.thermal_tint () in
  let count_note maximum =
    if maximum <= 0 then (if ko then "없음" else "none")
    else if ko then Printf.sprintf "최대 %d%s" maximum per
    else Printf.sprintf "max %d%s" maximum per
  in
  let calls_max = series_maximum ~sample:calls_sample buckets in
  let failed_max = series_maximum ~sample:failures_sample buckets in
  let p95_max = series_maximum ~sample:p95_sample buckets in
  let calls_note = count_note calls_max in
  let failed_note = count_note failed_max in
  let p95_note =
    (if ko then "최장 " else "worst ") ^ milliseconds_text (worst_p95_ms buckets)
  in
  let specs =
    [ ((if ko then "호출" else "Calls"), calls_max, calls_sample, calls_tint, calls_note)
    ; ((if ko then "실패" else "Failed"), failed_max, failures_sample, failed_tint, failed_note)
    ; ("p95", p95_max, p95_sample, p95_tint, p95_note)
    ]
  in
  let note_cells =
    List.fold_left
      (fun widest (_, _, _, _, note) -> max widest (Layout.display_width note))
      0 specs
  in
  let room_with_notes =
    cells - String.length margin - label_cells - note_gap - note_cells
  in
  let room_without_notes = cells - String.length margin - label_cells in
  let target_span room =
    if count <= 0 || room < count then None
    else Some (min room (max count (count * 3)))
  in
  let chosen =
    match target_span room_with_notes with
    | Some span -> Some (span, true)
    | None -> Option.map (fun span -> (span, false)) (target_span room_without_notes)
  in
  match chosen with
  | None -> []
  | Some (span, with_notes) ->
      let render_spec (label, maximum, sample, tint, note) =
        let curve_rows =
          draw_curve_rows ~tall ~span ~maximum ~sample ~tint buckets
        in
        List.mapi
          (fun index row_text ->
            let top = index = 0 in
            margin
            ^ Layout.fit_width (if top then label else "") label_cells
            ^ row_text
            ^
            if with_notes && top then
              String.make note_gap ' ' ^ Theme.recede () ^ note ^ Ansi.reset
            else "")
          curve_rows
      in
      List.concat_map render_spec specs
      @ ruler ~span ~series_width buckets

(* One bucket as the table reads it. A bucket in which no call ran has zero
   calls and nothing else: no failed calls to count and no latency. *)
type reading = {
  time : string;
  activity : Series.tool_series_activity;
  calls : string;
  failed : string;
  rate : string;
  p95 : string;
}

let reading_of series_width (bucket : Series.tool_series_bucket) =
  let time = time_text series_width bucket.Series.tsb_start in
  match bucket.Series.tsb_activity with
  | Series.Series_idle as activity ->
      { time; activity; calls = "0"; failed = no_call_mark; rate = no_call_mark;
        p95 = no_call_mark }
  | Series.Series_active active as activity ->
      { time;
        activity;
        calls = grouped_digits active.Series.tsc_calls;
        failed = grouped_digits active.Series.tsc_failures;
        rate =
          percent_text ~failures:active.Series.tsc_failures ~calls:active.Series.tsc_calls;
        p95 = milliseconds_text active.Series.tsc_p95_ms }

let reading_cells ~ko ~series_width ~widths ~with_rate reading =
  let time_width, calls_width, failed_width, rate_width, p95_width = widths in
  let idle, every_failed, any_failed =
    match reading.activity with
    | Series.Series_idle -> (true, false, false)
    | Series.Series_active active ->
        (false, every_call_failed active, active.Series.tsc_failures > 0)
  in
  let dim = if idle then Theme.recede () else "" in
  let failure_style =
    if every_failed then Theme.bad ()
    else if any_failed then Theme.warn ()
    else Theme.recede ()
  in
  [ Table.cell ~style:dim ~header:(time_header ~ko series_width) ~width:time_width
      reading.time;
    Table.cell ~style:dim ~align:Table.Right ~header:(if ko then "호출" else "CALLS") ~width:calls_width
      reading.calls;
    Table.cell ~style:failure_style ~align:Table.Right ~header:(if ko then "실패" else "FAILED")
      ~width:failed_width reading.failed ]
  @ (if with_rate then
       [ Table.cell ~style:failure_style ~align:Table.Right ~header:(if ko then "실패%" else "FAIL%")
           ~width:rate_width reading.rate ]
     else [])
  @ [ Table.cell ~style:dim ~align:Table.Right ~header:"P95" ~width:p95_width
        reading.p95 ]

let load_bar ~cells ~maximum_calls reading =
  match reading.activity with
  | Series.Series_idle ->
      Theme.recede ()
      ^ String.concat "" (List.init (max 0 cells) (fun _ -> "\xc2\xb7"))
      ^ Ansi.reset
  | Series.Series_active active ->
      (* Calls against the busiest bucket are a size, not a limit, so the
         fill walks the calls hue. A bucket in which every call failed is the
         anomaly, and its colour comes first. *)
      let scale =
        if every_call_failed active then
          Masc_tui_chart.Anomaly { paint = Theme.paint (); alarm = Masc_tui_chart.Alarm_bad }
        else Masc_tui_chart.Series { paint = Theme.paint (); series = Masc_tui_theme.Calls }
      in
      Masc_tui_chart.dot_meter_bar ~width:cells ~value:active.Series.tsc_calls
        ~max_value:(max 1 maximum_calls) ~scale
        ~track_style:(Theme.recede ()) ~reset:Ansi.reset ()

(* The newest bucket first: what the operator came to read is at the top, and
   the chart above already runs oldest to newest. *)
let table_lines ~ko ~cells t =
  let series_width = t.series.Series.tsr_width in
  let readings =
    List.rev_map (reading_of series_width) t.series.Series.tsr_buckets
  in
  let widest header pick =
    List.fold_left
      (fun widest reading -> max widest (Layout.display_width (pick reading)))
      (Layout.display_width header) readings
  in
  let widths =
    ( widest (time_header ~ko series_width) (fun reading -> reading.time),
      widest (if ko then "호출" else "CALLS") (fun reading -> reading.calls),
      widest (if ko then "실패" else "FAILED") (fun reading -> reading.failed),
      widest (if ko then "실패%" else "FAIL%") (fun reading -> reading.rate),
      widest "P95" (fun reading -> reading.p95) )
  in
  let inner = cells - String.length margin in
  let cells_for ~with_rate = reading_cells ~ko ~series_width ~widths ~with_rate in
  match readings with
  | [] -> []
  | first :: _ ->
      let open_tag = if ko then " 진행 중" else " open" in
      let open_cells = Layout.display_width open_tag in
      let with_rate = Table.used_width (cells_for ~with_rate:true first) <= inner in
      let used = Table.used_width (cells_for ~with_rate first) in
      let bar_cells = min widest_load_bar (inner - used - Table.cell_gap - open_cells) in
      let maximum_calls =
        List.fold_left
          (fun largest reading ->
            match reading.activity with
            | Series.Series_idle -> largest
            | Series.Series_active active -> max largest active.Series.tsc_calls)
          0 readings
      in
      let show_bar = bar_cells >= narrowest_load_bar && maximum_calls > 0 in
      let show_open =
        used + (if show_bar then Table.cell_gap + bar_cells else 0) + open_cells <= inner
      in
      let gap = String.make Table.cell_gap ' ' in
      let header =
        margin ^ Theme.recede () ^ Table.header_row (cells_for ~with_rate first)
        ^ (if show_bar then gap ^ (if ko then "부하" else "LOAD") else "")
        ^ Ansi.reset
      in
      let row index reading =
        margin ^ Table.row (cells_for ~with_rate reading)
        ^ (if show_bar then gap ^ load_bar ~cells:bar_cells ~maximum_calls reading else "")
        ^ if index = 0 && show_open then Theme.recede () ^ open_tag ^ Ansi.reset else ""
      in
      header :: List.mapi row readings

(* What the chart cannot say by itself, richest wording first, each wording
   being its rows: every row has its own scale, what the dot is and what red
   is. The newest bucket being open is left to the wording with room for it,
   because the table marks that row [open] too. *)
let legend_wordings ~ko =
  if ko then
    [ [ Printf.sprintf "각 줄은 자체 최대 구간 기준 · %s = 호출 없음" no_call_mark;
        "빨강 = 구간 내 호출 전체 실패 · 최신 구간은 집계 진행 중" ];
      [ Printf.sprintf "줄별 자체 최대 기준 · %s = 없음 · 빨강 = 전체 실패" no_call_mark ] ]
  else
    [ [ Printf.sprintf "Each row is scaled to its own largest bucket; %s = no call ran"
          no_call_mark;
        "Red = every call in the bucket failed; the newest bucket is still open" ];
      [ Printf.sprintf "Each row is scaled to its own max; %s = no call; red = every call failed"
          no_call_mark ] ]

let legend_shortest ~ko =
  if ko then
    Printf.sprintf "줄별 기준 · %s = 없음 · 빨강 = 전체 실패" no_call_mark
  else
    Printf.sprintf "Own scale per row; %s = no call; red = all failed" no_call_mark

(* The first wording with no more than [at_most] rows, all within [cells]. A
   width that none of them fits gets the shortest one, cut. *)
let legend ~ko ~cells ~at_most =
  let room = max 0 (cells - String.length margin) in
  let fits rows =
    List.length rows <= at_most
    && List.for_all (fun row -> Layout.display_width row <= room) rows
  in
  let rows =
    match List.find_opt fits (legend_wordings ~ko) with
    | Some rows -> rows
    | None -> [ Layout.truncate_end room (legend_shortest ~ko) ]
  in
  List.map (fun row -> Theme.recede () ^ margin ^ row ^ Ansi.reset) rows

(* The section's arrangements, richest first. Each step gives up one row's
   worth: the taller chart, then the blank row below the legend, then the
   blank row above the chart, then the legend's second row. The section
   draws the first arrangement the rows hold, so no row is left empty that a
   richer one could have used. The smallest is drawn even when it does not
   fit; the screen then scrolls the section and says so on its last row. The
   table never gives way: every arrangement keeps all of it. *)
let lines ?(ko = false) ~width:cells ~rows t =
  let calls, failures, deferred = totals t.series.Series.tsr_buckets in
  let heading = heading ~ko ~cells t in
  if calls = 0 then
    [ heading
    ; if ko then " 이 기간에 실행된 도구 호출이 없습니다"
      else " No tool call ran in this window" ]
  else
    let top = [ heading; totals_line ~ko ~calls ~failures ~deferred ] in
    let table = table_lines ~ko ~cells t in
    let arrange ~tall ~gap_above ~gap_below ~legend_rows =
      top
      @ (if gap_above then [ "" ] else [])
      @ chart_lines ~ko ~tall ~cells t
      @ legend ~ko ~cells ~at_most:legend_rows
      @ (if gap_below then [ "" ] else [])
      @ table
    in
    let richer =
      [ (fun () -> arrange ~tall:tall_rows ~gap_above:true ~gap_below:true ~legend_rows:2);
        (fun () -> arrange ~tall:2 ~gap_above:true ~gap_below:true ~legend_rows:2);
        (fun () -> arrange ~tall:1 ~gap_above:true ~gap_below:true ~legend_rows:2);
        (fun () -> arrange ~tall:1 ~gap_above:true ~gap_below:false ~legend_rows:2);
        (fun () -> arrange ~tall:1 ~gap_above:false ~gap_below:false ~legend_rows:2) ]
    in
    let smallest () = arrange ~tall:1 ~gap_above:false ~gap_below:false ~legend_rows:1 in
    match List.find_map (fun arrangement ->
        let drawn = arrangement () in
        if List.length drawn <= rows then Some drawn else None) richer with
    | Some drawn -> drawn
    | None -> smallest ()

(* The Dashboard's row names its window in as few cells as the row can spare.
   A day reads 1d, not 24h (RFC tui-one-screen-grammar 6.2). *)
let short_span ~ko = function
  | Last_day -> if ko then "1일" else "1d"
  | Last_week -> if ko then "7일" else "7d"
  | Last_fortnight -> if ko then "14일" else "14d"

let summary_label ~ko window =
  Printf.sprintf " %s %s" (if ko then "도구 호출" else "Tool calls") (short_span ~ko window)
let summary_gap = "  "

(* The label, the calls as one glyph per bucket, then the total and the failed
   calls. The chart goes first when the row is too narrow for it, then the
   rest is cut. *)
let summary_line ?(ko = false) ~cells t =
  let label = summary_label ~ko t.window in
  let buckets = t.series.Series.tsr_buckets in
  let calls, failures, _deferred = totals buckets in
  if calls = 0 then
    Theme.recede ()
    ^ Layout.truncate_end cells (label ^ summary_gap ^ (if ko then "호출 없음" else "no calls"))
    ^ Ansi.reset
  else
    let figures_plain =
      if ko then
        Printf.sprintf "%s건 · 실패 %s" (grouped_digits calls) (grouped_digits failures)
      else
        Printf.sprintf "%s · %s failed" (grouped_digits calls) (grouped_digits failures)
    in
    let fail_style =
      if failures > 0 && failures = calls then Theme.bad ()
      else if failures > 0 then Theme.warn ()
      else Theme.recede ()
    in
    let figures_styled =
      let calls_str =
        if ko then Printf.sprintf "%s건" (grouped_digits calls)
        else grouped_digits calls
      in
      let fail_str =
        if ko then Printf.sprintf "실패 %s" (grouped_digits failures)
        else Printf.sprintf "%s failed" (grouped_digits failures)
      in
      let fail_colored = wrap_style fail_style fail_str in
      calls_str ^ wrap_style (Theme.recede ()) " · " ^ fail_colored
    in
    let without_chart =
      Layout.display_width label + String.length summary_gap
      + Layout.display_width figures_plain
    in
    let chart_room = List.length buckets + String.length summary_gap in
    if without_chart + chart_room <= cells then
      let maximum = series_maximum ~sample:calls_sample buckets in
      let tint = Theme.series_tint Masc_tui_theme.Calls in
      let curve =
        match
          draw_curve_rows ~tall:1 ~span:(List.length buckets) ~maximum
            ~sample:calls_sample ~tint buckets
        with
        | row :: _ -> row
        | [] -> ""
      in
      Theme.recede () ^ label ^ Ansi.reset ^ summary_gap
      ^ curve
      ^ summary_gap ^ figures_styled
    else if without_chart <= cells then
      Theme.recede () ^ label ^ Ansi.reset ^ summary_gap ^ figures_styled
    else
      let label_w = Layout.display_width label + String.length summary_gap in
      if label_w < cells then
        Theme.recede () ^ label ^ Ansi.reset ^ summary_gap
        ^ Layout.truncate_end (cells - label_w) figures_plain
      else
        Theme.recede ()
        ^ Layout.truncate_end cells (label ^ summary_gap ^ figures_plain)
        ^ Ansi.reset

let summary_note ?(ko = false) ~cells window note =
  Theme.recede ()
  ^ Layout.truncate_end cells (summary_label ~ko window ^ summary_gap ^ note)
  ^ Ansi.reset
