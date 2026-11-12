module Series = Masc.Tui_decode_tool_series
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

(* [Masc_tui_chart] draws eight levels, 0 to 7. *)
let top_level = 7

let mark level = Masc_tui_chart.sparkline ~min:0 ~max:top_level [ level ]

(* A value above zero never draws the lowest level, which is what zero draws:
   one failed call among thirty is told apart from none by its shape and not
   by its colour alone. *)
let level_of ~maximum value =
  if maximum <= 0.0 || value <= 0.0 then 0
  else
    max 1
      (min top_level
         (int_of_float (Float.floor (value /. maximum *. float_of_int top_level))))

let every_call_failed (calls : Series.tool_series_calls) =
  calls.Series.tsc_failures = calls.Series.tsc_calls

let grouped_digits = Masc_tui_value.Count.grouped

let milliseconds_text ms =
  if ms >= 1000.0 then Printf.sprintf "%.1f s" (ms /. 1000.0)
  else if ms >= 100.0 then Printf.sprintf "%.0f ms" ms
  else if ms >= 10.0 then Printf.sprintf "%.1f ms" ms
  else Printf.sprintf "%.2f ms" ms

let percent_text ~failures ~calls =
  if failures = 0 then "0%"
  else Printf.sprintf "%.1f%%" (100.0 *. float_of_int failures /. float_of_int calls)

let unit_suffix = function
  | Series.Series_hour -> "/h"
  | Series.Series_day -> "/d"

let time_text series_width start =
  let moment = Unix.gmtime start in
  match series_width with
  | Series.Series_hour ->
      Printf.sprintf "%02d-%02d %02d:00" (moment.Unix.tm_mon + 1) moment.Unix.tm_mday
        moment.Unix.tm_hour
  | Series.Series_day ->
      Printf.sprintf "%02d-%02d" (moment.Unix.tm_mon + 1) moment.Unix.tm_mday

let time_header = function
  | Series.Series_hour -> "HOUR (UTC)"
  | Series.Series_day -> "DAY (UTC)"

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

let span_name = function
  | Last_day -> "last 24 hours"
  | Last_week -> "7 UTC days"
  | Last_fortnight -> "14 UTC days"

let span_text window =
  span_name window
  ^
  match width window with
  | Series.Series_hour -> " · per UTC hour"
  | Series.Series_day -> " · per UTC day"

(* The first of the wordings that fits [cells]; the last one is cut to [cells]
   when it does not fit either. *)
let rec first_within ~cells wording rest =
  match rest with
  | [] -> Layout.take_cells wording cells
  | next :: later ->
      if Layout.display_width wording <= cells then wording
      else first_within ~cells next later

(* The longest wording that fits goes first. The time the numbers are from
   stays in every wording: the answer can be a read behind the store, and this
   time is what says by how much. *)
let heading ~cells t =
  let as_of = Unix.gmtime t.series.Series.tsr_generated_at in
  let time =
    Printf.sprintf "as of %02d-%02d %02d:%02d UTC" (as_of.Unix.tm_mon + 1)
      as_of.Unix.tm_mday as_of.Unix.tm_hour as_of.Unix.tm_min
  in
  first_within ~cells
    (Printf.sprintf " Tool calls (%s) · %s" (span_text t.window) time)
    [ Printf.sprintf " Tool calls (%s) · %s" (span_name t.window) time;
      Printf.sprintf " Tool calls · %s" time;
      " " ^ time ]

let note_lines ~days note =
  let span =
    match window_of_days days with
    | Some window -> span_text window
    | None -> Printf.sprintf "%d UTC days" days
  in
  [ Printf.sprintf " Tool calls (%s) · %s" span note ]

let totals_line ~calls ~failures ~deferred =
  Printf.sprintf " %s calls · %s failed (%s)%s" (grouped_digits calls)
    (grouped_digits failures)
    (percent_text ~failures ~calls)
    (if deferred = 0 then "" else Printf.sprintf " · %s deferred" (grouped_digits deferred))

(* One glyph per bucket, scaled to the row's own largest value. A bucket in
   which every call failed is red top to bottom, so an outage reads as one
   column across the three rows. *)
let chart_cells ~(value : Series.tool_series_calls -> float) buckets =
  let maximum =
    List.fold_left
      (fun largest (bucket : Series.tool_series_bucket) ->
        match bucket.Series.tsb_activity with
        | Series.Series_idle -> largest
        | Series.Series_active active -> Float.max largest (value active))
      0.0 buckets
  in
  let cells =
    List.map
      (fun (bucket : Series.tool_series_bucket) ->
        match bucket.Series.tsb_activity with
        | Series.Series_idle -> (no_call_mark, Theme.recede ())
        | Series.Series_active active ->
            let style =
              if every_call_failed active then Theme.bad ()
              else if value active = 0.0 then Theme.recede ()
              else Theme.info ()
            in
            (mark (level_of ~maximum (value active)), style))
      buckets
  in
  (maximum, cells)

(* How many cells a bucket's mark fills and how many blanks separate two marks,
   widest first. The last one is the sparkline proper, one cell per bucket. *)
let spacings = [ (3, 1); (2, 1); (1, 1); (1, 0) ]

let spacing_span ~count (stretch, gap) = (count * stretch) + ((count - 1) * gap)

let draw_cells ~stretch ~gap cells =
  String.concat (String.make gap ' ')
    (List.map
       (fun (glyph, style) ->
         style ^ String.concat "" (List.init stretch (fun _ -> glyph)) ^ Ansi.reset)
       cells)

(* The oldest and the newest bucket named at the two ends of a rule. *)
let ruler ~span ~series_width buckets =
  match buckets, List.rev buckets with
  | (first : Series.tool_series_bucket) :: _, (last : Series.tool_series_bucket) :: _ ->
      let oldest = time_text series_width first.Series.tsb_start in
      let newest = time_text series_width last.Series.tsb_start in
      let labels = String.length oldest + String.length newest + 2 in
      if span < labels + 2 then []
      else
        [ margin
          ^ String.make label_cells ' '
          ^ Theme.recede ()
          ^ oldest ^ " "
          ^ String.concat "" (List.init (span - labels) (fun _ -> Ansi.box_h))
          ^ " " ^ newest ^ Ansi.reset ]
  | [], _ | _, [] -> []

let chart_lines ~cells t =
  let buckets = t.series.Series.tsr_buckets in
  let series_width = t.series.Series.tsr_width in
  let count = List.length buckets in
  let per = unit_suffix series_width in
  let calls_maximum, calls_cells =
    chart_cells ~value:(fun active -> float_of_int active.Series.tsc_calls) buckets
  in
  let failed_maximum, failed_cells =
    chart_cells ~value:(fun active -> float_of_int active.Series.tsc_failures) buckets
  in
  let p95_maximum, p95_cells =
    chart_cells ~value:(fun active -> active.Series.tsc_p95_ms) buckets
  in
  let count_note maximum =
    if maximum <= 0.0 then "none"
    else Printf.sprintf "max %d%s" (int_of_float maximum) per
  in
  let rows =
    [ ("Calls", calls_cells, count_note calls_maximum);
      ("Failed", failed_cells, count_note failed_maximum);
      ("p95", p95_cells, "worst " ^ milliseconds_text p95_maximum) ]
  in
  let note_cells =
    List.fold_left
      (fun widest (_, _, note) -> max widest (Layout.display_width note))
      0 rows
  in
  let room_with_notes =
    cells - String.length margin - label_cells - note_gap - note_cells
  in
  let room_without_notes = cells - String.length margin - label_cells in
  let fitting room =
    List.find_opt (fun spacing -> spacing_span ~count spacing <= room) spacings
  in
  let chosen =
    if count = 0 then None
    else
      match fitting room_with_notes with
      | Some spacing -> Some (spacing, true)
      | None -> Option.map (fun spacing -> (spacing, false)) (fitting room_without_notes)
  in
  match chosen with
  | None -> []
  | Some (((stretch, gap) as spacing), with_notes) ->
      let row (label, drawn, note) =
        margin
        ^ Layout.fit_width label label_cells
        ^ draw_cells ~stretch ~gap drawn
        ^
        if with_notes then
          String.make note_gap ' ' ^ Theme.recede () ^ note ^ Ansi.reset
        else ""
      in
      List.map row rows
      @ ruler ~span:(spacing_span ~count spacing) ~series_width buckets

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

let reading_cells ~series_width ~widths ~with_rate reading =
  let time_width, calls_width, failed_width, rate_width, p95_width = widths in
  let idle, every_failed =
    match reading.activity with
    | Series.Series_idle -> (true, false)
    | Series.Series_active active -> (false, every_call_failed active)
  in
  let dim = if idle then Theme.recede () else "" in
  let failure_style = if every_failed then Theme.bad () else dim in
  [ Table.cell ~style:dim ~header:(time_header series_width) ~width:time_width
      reading.time;
    Table.cell ~style:dim ~align:Table.Right ~header:"CALLS" ~width:calls_width
      reading.calls;
    Table.cell ~style:failure_style ~align:Table.Right ~header:"FAILED"
      ~width:failed_width reading.failed ]
  @ (if with_rate then
       [ Table.cell ~style:failure_style ~align:Table.Right ~header:"FAIL%"
           ~width:rate_width reading.rate ]
     else [])
  @ [ Table.cell ~style:dim ~align:Table.Right ~header:"P95" ~width:p95_width
        reading.p95 ]

let load_bar ~cells ~maximum_calls reading =
  match reading.activity with
  | Series.Series_idle -> ""
  | Series.Series_active active ->
      let filled =
        max 1
          (int_of_float
             (Float.round
                (float_of_int active.Series.tsc_calls
                /. float_of_int (max 1 maximum_calls)
                *. float_of_int cells)))
      in
      let style = if every_call_failed active then Theme.bad () else Theme.info () in
      style
      ^ String.concat "" (List.init filled (fun _ -> "\xe2\x96\x88"))
      ^ Ansi.reset

(* The newest bucket first: what the operator came to read is at the top, and
   the chart above already runs oldest to newest. *)
let table_lines ~cells t =
  let series_width = t.series.Series.tsr_width in
  let readings =
    List.rev_map (reading_of series_width) t.series.Series.tsr_buckets
  in
  let widest header pick =
    List.fold_left
      (fun widest reading -> max widest (Layout.display_width (pick reading)))
      (String.length header) readings
  in
  let widths =
    ( widest (time_header series_width) (fun reading -> reading.time),
      widest "CALLS" (fun reading -> reading.calls),
      widest "FAILED" (fun reading -> reading.failed),
      widest "FAIL%" (fun reading -> reading.rate),
      widest "P95" (fun reading -> reading.p95) )
  in
  let inner = cells - String.length margin in
  let cells_for ~with_rate = reading_cells ~series_width ~widths ~with_rate in
  match readings with
  | [] -> []
  | first :: _ ->
      let with_rate = Table.used_width (cells_for ~with_rate:true first) <= inner in
      let used = Table.used_width (cells_for ~with_rate first) in
      let bar_cells = min widest_load_bar (inner - used - Table.cell_gap) in
      let maximum_calls =
        List.fold_left
          (fun largest reading ->
            match reading.activity with
            | Series.Series_idle -> largest
            | Series.Series_active active -> max largest active.Series.tsc_calls)
          0 readings
      in
      let show_bar = bar_cells >= narrowest_load_bar && maximum_calls > 0 in
      let gap = String.make Table.cell_gap ' ' in
      let header =
        margin ^ Theme.recede () ^ Table.header_row (cells_for ~with_rate first)
        ^ (if show_bar then gap ^ "LOAD" else "")
        ^ Ansi.reset
      in
      let row index reading =
        margin ^ Table.row (cells_for ~with_rate reading)
        ^ (if show_bar then gap ^ load_bar ~cells:bar_cells ~maximum_calls reading else "")
        ^ if index = 0 then Theme.recede () ^ " open" ^ Ansi.reset else ""
      in
      header :: List.mapi row readings

(* What the chart cannot say by itself, richest wording first, each wording
   being its rows: every row has its own scale, what the dot is and what red
   is. The newest bucket being open is left to the wording with room for it,
   because the table marks that row [open] too. *)
let legend_wordings =
  [ [ Printf.sprintf "Each row is scaled to its own largest bucket; %s = no call ran"
        no_call_mark;
      "Red = every call in the bucket failed; the newest bucket is still open" ];
    [ Printf.sprintf "Each row is scaled to its own max; %s = no call; red = every call failed"
        no_call_mark ] ]

let legend_shortest =
  Printf.sprintf "Own scale per row; %s = no call; red = all failed" no_call_mark

(* The first wording with no more than [at_most] rows, all within [cells]. A
   width that none of them fits gets the shortest one, cut. *)
let legend ~cells ~at_most =
  let room = max 0 (cells - String.length margin) in
  let fits rows =
    List.length rows <= at_most
    && List.for_all (fun row -> Layout.display_width row <= room) rows
  in
  let rows =
    match List.find_opt fits legend_wordings with
    | Some rows -> rows
    | None -> [ Layout.take_cells legend_shortest room ]
  in
  List.map (fun row -> Theme.recede () ^ margin ^ row ^ Ansi.reset) rows

(* Two blank rows and a two-row legend are worth their rows while the section
   fits. Taller than [rows], the legend takes one row and the blank rows go, so
   the table shows more of its rows without a scroll. *)
let lines ~width:cells ~rows t =
  let calls, failures, deferred = totals t.series.Series.tsr_buckets in
  let heading = heading ~cells t in
  if calls = 0 then [ heading; " No tool call ran in this window" ]
  else
    let top = [ heading; totals_line ~calls ~failures ~deferred ] in
    let chart = chart_lines ~cells t in
    let table = table_lines ~cells t in
    let spaced = top @ [ "" ] @ chart @ legend ~cells ~at_most:2 @ [ "" ] @ table in
    if List.length spaced <= rows then spaced
    else top @ chart @ legend ~cells ~at_most:1 @ table

(* The Dashboard's row names its window in as few cells as the row can spare. *)
let short_span = function
  | Last_day -> "24h"
  | Last_week -> "7d"
  | Last_fortnight -> "14d"

let summary_label window = Printf.sprintf " Tool calls %s" (short_span window)
let summary_gap = "  "

(* The label, the calls as one glyph per bucket, then the total and the failed
   calls. The chart goes first when the row is too narrow for it, then the
   rest is cut. *)
let summary_line ~cells t =
  let label = summary_label t.window in
  let buckets = t.series.Series.tsr_buckets in
  let calls, failures, _deferred = totals buckets in
  if calls = 0 then
    Theme.recede ()
    ^ Layout.take_cells (label ^ summary_gap ^ "no calls") cells
    ^ Ansi.reset
  else
    let figures =
      Printf.sprintf "%s · %s failed" (grouped_digits calls) (grouped_digits failures)
    in
    let without_chart =
      Layout.display_width label + String.length summary_gap
      + Layout.display_width figures
    in
    let chart_room = List.length buckets + String.length summary_gap in
    if without_chart + chart_room <= cells then
      let _, drawn =
        chart_cells
          ~value:(fun active -> float_of_int active.Series.tsc_calls)
          buckets
      in
      Theme.recede () ^ label ^ Ansi.reset ^ summary_gap
      ^ draw_cells ~stretch:1 ~gap:0 drawn
      ^ summary_gap ^ figures
    else if without_chart <= cells then
      Theme.recede () ^ label ^ Ansi.reset ^ summary_gap ^ figures
    else
      Theme.recede ()
      ^ Layout.take_cells (label ^ summary_gap ^ figures) cells
      ^ Ansi.reset

let summary_note ~cells window note =
  Theme.recede ()
  ^ Layout.take_cells (summary_label window ^ summary_gap ^ note) cells
  ^ Ansi.reset
