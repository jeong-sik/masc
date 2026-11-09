module Model = Masc_tui_keeper_list_model
module Grid = Masc_tui_keeper_grid
module Pulse = Masc_tui_keeper_pulse
module Next = Masc_tui_keeper_next_run
module Memory = Masc_tui_keeper_memory_reading
module Layout = Masc_tui_message_layout
module Decode = Masc.Tui_decode
module Theme = Masc_tui_ansi.Theme
module Ansi = Masc_tui_ansi.Ansi

let runtime (row : Model.row) =
  match row.reading.Masc_tui_keeper_control.liveness with
  | Masc_tui_keeper_control.Present row -> Some row
  | Masc_tui_keeper_control.Absent | Masc_tui_keeper_control.Unobserved
  | Masc_tui_keeper_control.Invalid _ -> None

let name (row : Model.row) = row.keeper.Decode.k_name
let clean = Terminal_text.single_line

type bucket = Failures | Recoveries | Sound | Paused | Fresh | Today | Cooling | Dormant | Unknown

let bucket ~now ~age view row =
  match view with
  | Model.By_age ->
      (match age row with
       | Model.Age_within_3h -> Fresh | Model.Age_within_day -> Today
       | Model.Age_within_3d -> Cooling | Model.Age_older -> Dormant
       | Model.Age_unknown -> Unknown)
  | Model.(Plain | By_state | By_cause | By_time | By_memory | By_runtime | Day_wall) ->
      (match Grid.verdict ~now (runtime row) with
       | Grid.Failing _ -> Failures | Grid.Recovered -> Recoveries
       | Grid.Sound -> Sound | Grid.Paused -> Paused | Grid.Other -> Unknown)

let odd_dormant row =
  match runtime row with
  | Some row -> not row.Decode.kr_paused &&
      (match row.kr_activation_mode with
       | Decode.Activation_autonomous -> true
       | Decode.Activation_manual | Decode.Activation_on_demand -> false)
  | None -> false

let header ~now ~cells ~view ~selected ~age rows =
  let groups = match view with
    | Model.By_age ->
        [Fresh, "█", "fresh", Theme.info (); Today, "▆", "today", Ansi.reset;
         Cooling, "▃", "cooling", Theme.recede (); Dormant, "▁", "dormant", Theme.recede ();
         Unknown, "?", "unknown", Theme.recede ()]
    | Model.(Plain | By_state | By_cause | By_time | By_memory | By_runtime | Day_wall) ->
        [Failures, "!", "failing", Theme.warn (); Recoveries, "✓", "recovered", Theme.ok ();
         Sound, "●", "ok", Theme.ok (); Paused, "○", "paused", Theme.recede ();
         Unknown, "?", "unknown", Theme.recede ()] in
  let readings = List.map (fun row -> row, bucket ~now ~age view row) rows in
  let groups = List.filter_map (fun (key, mark, word, style) ->
    let members = List.filter_map (fun (row, at) -> if at = key then Some row else None) readings in
    match members with [] -> None | _ :: _ -> Some (key, mark, word, style, members)) groups in
  let label long (_, mark, word, _, members) =
    if long then Printf.sprintf "%s %d %s" mark (List.length members) word
    else mark ^ string_of_int (List.length members) in
  let long = List.fold_left (fun n ((_, _, _, _, members) as group) ->
    n + Layout.display_width (label true group) + List.length members + 3) 0 groups <= cells in
  let draw ((key, _, _, style, members) as group) =
    let marks = List.map (fun row ->
      let mark, tone = match key with
        | Paused -> "·", Theme.recede ()
        | Failures ->
            (match Grid.verdict ~now (runtime row) with
             | Grid.Failing { resting = true } -> "▫", Theme.recede ()
             | Grid.Failing { resting = false } | Grid.Paused | Grid.Recovered | Grid.Sound | Grid.Other -> "▪", style)
        | Dormant -> if odd_dormant row then "▪", Theme.warn () else "▫", style
        | Unknown -> "?", Theme.recede ()
        | Recoveries | Sound | Fresh | Today | Cooling -> "▪", style in
      tone ^ (if selected = Some (name row) then Ansi.bold else "") ^ mark ^ Ansi.reset) members in
    style ^ label long group ^ Ansi.reset ^ " " ^ String.concat "" marks in
  String.concat "  " (List.map draw groups)

type fleet_cells = { name : string; pulse : string; strip : string; due : string }

let failed_count readings index =
  List.fold_left (fun (count, unknown) slots ->
    match List.nth slots index with
    | Pulse.Half_hour_failed | Pulse.Half_hour_failed_and_ok -> count + 1, unknown
    | Pulse.Half_hour_unknown -> count, true
    | Pulse.Half_hour_quiet | Pulse.Half_hour_ok -> count, unknown) (0, false) readings

let fleet_cells ~now ~(grid : Grid.t) ~wakes rows =
  let readings = List.map (fun row ->
    let pulse = Option.bind (runtime row) (fun row -> row.Decode.kr_recent_turns) in
    Pulse.half_hours ~now ~count:grid.side_cells pulse) rows in
  let counts = List.init grid.side_cells (failed_count readings) in
  let peak = List.fold_left (fun p (n, _) -> max p n) 0 counts in
  let pulse = String.concat "" (List.map (fun (n, unknown) ->
    if n > 0 then Theme.warn () ^ Grid.level_glyph ~peak n ^ Ansi.reset
    else if unknown then "?" else "·") counts) in
  let active = List.filter (fun row -> match runtime row with
    | Some row -> not row.Decode.kr_paused | None -> true) rows in
  let future = match active with
    | [] -> List.init (Grid.strip_cells grid) (fun _ -> Next.Wakes 0)
    | _ :: _ -> Next.sum_wake_strips (List.map (fun row ->
        match runtime row with Some _ -> wakes row
        | None -> Next.unknown_strip ~ahead:(Grid.strip_cells grid - 1)) active) in
  let wake_peak = List.fold_left (fun p slot -> match slot with
    | Next.Wakes n -> max p n | Next.Wakes_unknown -> p) 0 future in
  let strip = String.concat "" (List.map (function
    | Next.Wakes_unknown -> "?"
    | Next.Wakes 0 -> "·"
    | Next.Wakes n -> Theme.info () ^ Grid.level_glyph ~peak:wake_peak n ^ Ansi.reset) future) in
  let pulse_max = if peak = 0 && List.exists snd counts then "?" else string_of_int peak in
  let wake_max = if wake_peak = 0 && List.exists (function
    | Next.Wakes_unknown -> true | Next.Wakes _ -> false) future then "?" else string_of_int wake_peak in
  { name = (if grid.name_cells >= 21 then "fleet fail/30m max " else "fleet max ") ^ pulse_max
  ; pulse; strip
  ; due = let label = "max " ^ wake_max in
      if Layout.display_width label <= Grid.due_cells then label else Layout.compact_count wake_peak }

let selected_summary ~now ~activity_cell ~next_run ~recurrence ~memory row =
  let observed = runtime row in
  let verdict = Grid.verdict ~now observed in
  let age = Option.bind row.Model.last_activity_at (fun since -> Layout.age_text ~now ~since) in
  let since = match verdict, observed with
    | Grid.Failing _, Some runtime ->
        Some (match runtime.Decode.kr_failing_since with
          | Some at when Float.is_finite at && at <= now ->
              "since " ^ Grid.dated_clock_text ~now ~localtime:Unix.localtime at
          | Some _ | None -> "since ?")
    | Grid.Failing _, None -> Some "since ?"
    | (Grid.Paused | Grid.Recovered | Grid.Sound | Grid.Other), (Some _ | None) -> None in
  let next = match next_run with
    | Next.Scheduled_at at ->
        Some (if Float.is_finite at then
          let time = Unix.localtime at in
          Printf.sprintf "◷ %02d:%02d" time.Unix.tm_hour time.Unix.tm_min
          else "◷ ?")
    | Next.No_schedule | Next.Late_since _ | Next.Held_current _ | Next.Held_as_of _
    | Next.Not_before _ | Next.Unknown ->
        Option.map (fun (cell : Masc_tui_keeper_axis_cell.t) -> cell.text)
          (Next.cell ~now next_run) in
  let next = Option.map (fun text -> text ^ (match recurrence with
    | Some (Schedule_domain.Interval { interval_sec }) -> " every " ^ Grid.short_span (float_of_int interval_sec)
    | Some (Schedule_domain.One_shot as recurrence)
    | Some (Schedule_domain.Daily _ as recurrence)
    | Some (Schedule_domain.Cron _ as recurrence) -> " " ^ clean (Schedule_domain.recurrence_summary recurrence)
    | None -> "")) next in
  let lag = match memory with
    | Memory.Row { lag = Memory.Lag n; _ } -> if n > 0 then Some ("lag " ^ string_of_int n) else None
    | Memory.Row { lag = Memory.Lag_unmeasured; _ } | Memory.Unknown -> Some "lag ?"
    | Memory.Refused _ -> Some "lag !"
    | Memory.No_row -> None in
  let head = match verdict, observed with
    | Grid.Failing _, Some row ->
        (match row.Decode.kr_runtime_path_rest with
         | Ok (Some (Decode.Path_rest_serving path)) -> Some ("▹ " ^ clean path.runtime_id)
         | Ok (Some (Decode.Path_rest_resting path)) -> Some ("◌ wait " ^ clean path.runtime_id)
         | Error _ | Ok None -> Some "▹ ?")
    | (Grid.Paused | Grid.Recovered | Grid.Sound | Grid.Other), (Some _ | None)
    | Grid.Failing _, None -> None in
  let first = clean (name row) ^ " " ^ activity_cell
    ^ (match age with Some age -> " " ^ age | None -> "") in
  String.concat " · " (first :: List.filter_map Fun.id [since; next; lag; head])
