module Model = Masc_tui_keeper_list_model
module Grid = Masc_tui_keeper_grid
module Pulse = Masc_tui_keeper_pulse
module Next = Masc_tui_keeper_next_run
module Memory = Masc_tui_keeper_memory_reading
module Layout = Masc_tui_message_layout
module Terminal_text = Masc_tui_ansi.Terminal_text
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

type bucket =
  | Failures
  | Config_error
  | Unexpected_offline
  | Recoveries
  | Sound
  | Paused
  | Offline
  | Fresh
  | Today
  | Cooling
  | Dormant
  | Unknown

let bucket ~now ~age view (row : Model.row) =
  match view with
  | Model.By_age ->
      (match age row with
       | Model.Age_within_3h -> Fresh | Model.Age_within_day -> Today
       | Model.Age_within_3d -> Cooling | Model.Age_older -> Dormant
       | Model.Age_unknown -> Unknown)
  | Model.(Plain | By_state | By_cause | By_time | By_memory | By_runtime | Day_wall) ->
      (match row.reading.Masc_tui_keeper_control.liveness with
       | Masc_tui_keeper_control.Present r ->
           if row.reading.Masc_tui_keeper_control.paused then Paused
           else
             (match Grid.verdict ~now (Some r) with
              | Grid.Failing _ -> Failures
              | Grid.Offline { unexpected = true } -> Unexpected_offline
              | Grid.Recovered -> Recoveries
              | Grid.Sound -> Sound
              | Grid.Paused -> Paused
              | Grid.Offline { unexpected = false } -> Offline
              | Grid.Other -> Unknown)
       | Masc_tui_keeper_control.Invalid _ -> Config_error
       | Masc_tui_keeper_control.Absent ->
           if row.reading.Masc_tui_keeper_control.paused then Paused else Offline
       | Masc_tui_keeper_control.Unobserved ->
           if row.reading.Masc_tui_keeper_control.paused then Paused else Unknown)

let header ~ko ~now ~cells ~view ~selected:_ ~age rows =
  let say korean english = if ko then korean else english in
  (* A group of Keepers wears the status mark of its verdict, in that mark's
     colour (RFC tui-one-screen-grammar §7.2); config errors keep the read-failed
     mark and unread rows keep the unread mark. *)
  let status mark = Masc_tui_value.Mark.glyph mark, Theme.status_tone mark in
  let unreported = Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Unreported in
  let unread = Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Unread in
  let read_failed = Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Read_failed in
  (* The age words name the bound each bucket is cut at, as [bucket] reads
     it off [Model.age]. *)
  let groups = match view with
    | Model.By_age ->
        [Fresh, "█", say "3시간 안" "fresh", "", Theme.info ();
         Today, "▆", say "하루 안" "today", "", Ansi.reset;
         Cooling, "▃", say "사흘 안" "cooling", "", Theme.recede ();
         Dormant, "▁", say "더 오래" "dormant", "", Theme.recede ();
         Unknown, unreported, say "나이 보고 안 됨" "age not reported", "", Theme.recede ()]
    | Model.(Plain | By_state | By_cause | By_time | By_memory | By_runtime | Day_wall) ->
        let failed, failed_tone = status Masc_tui_value.Mark.Failed in
        let caution, caution_tone = status Masc_tui_value.Mark.Caution in
        let settled, settled_tone = status Masc_tui_value.Mark.Settled in
        let paused, paused_tone = status Masc_tui_value.Mark.Paused in
        [Failures, failed, say "실패" "failing", "", failed_tone;
         Config_error, read_failed, say "설정 오류" "config error", say "오류" "err", failed_tone;
         Unexpected_offline, caution, say "자율 꺼짐" "auto off", say "꺼짐" "off", caution_tone;
         Recoveries, caution, say "복구" "recovered", say "복구" "rec", caution_tone;
         Sound, settled, say "정상" "ok", "", settled_tone;
         Paused, paused, say "일시정지" "paused", say "정지" "p", paused_tone;
         Offline, paused, say "오프라인" "offline", say "오프" "off", paused_tone;
         Unknown, unread, say "미조회" "unread", "", Theme.recede ()] in
  let readings = List.map (fun row -> row, bucket ~now ~age view row) rows in
  let groups = List.filter_map (fun (key, mark, word, short, style) ->
    let members = List.filter_map (fun (row, at) -> if at = key then Some row else None) readings in
    match members with [] -> None | _ :: _ -> Some (mark, word, short, style, List.length members)) groups in
  let label long (mark, word, short, _, count) =
    if not long then
      if String.equal short "" then mark ^ string_of_int count
      else mark ^ short ^ string_of_int count
    else if ko then Printf.sprintf "%s %s %d" mark word count
    else Printf.sprintf "%s %d %s" mark count word in
  let sep_w = 2 * max 0 (List.length groups - 1) in
  let base_w long =
    sep_w + List.fold_left (fun n g -> n + Layout.display_width (label long g)) 0 groups in
  let long = base_w true <= max 0 (cells - 2) in
  match groups with
  | [] -> ""
  | _ :: _ ->
      "  "
      ^ String.concat "  "
          (List.map (fun ((_, _, _, style, _) as group) ->
             style ^ label long group ^ Ansi.reset) groups)

type wake_style = Keeper_wakes | Wake_counts

let unreported_mark = Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Unreported

let window_label ?(style = Theme.recede ()) ~cells full narrow =
  style
  ^ Layout.fit_width (if Layout.display_width full <= cells then full else narrow) cells
  ^ Ansi.reset

(* A band with no cell to draw holds one mark at its left, as a graph that was
   never read does (RFC tui-one-screen-grammar 5.6, 6.4): [?] when nothing in
   the band was reported, [—] when the band is read and holds no run. Why it
   was not reported is the selected row's detail. *)
let unreported_band ~cells = window_label ~cells unreported_mark unreported_mark
let empty_band ~cells = window_label ~cells Masc_tui_theme.Glyph.no_value Masc_tui_theme.Glyph.no_value

let history_unknown_label ~cells = unreported_band ~cells

let wake_summary ~ko slots =
  let cells = List.length slots in
  let known, unknown = List.fold_left (fun (known, unknown) -> function
    | Next.Wakes count -> known + max 0 count, unknown
    | Next.Wakes_with_unknown count -> known + max 0 count, true
    | Next.Wakes_unknown -> known, true) (0, false) slots in
  if cells = 0 then "" else
  let wakes_tint = Theme.series_tint Masc_tui_theme.Wakes in
  match known, unknown with
  | 0, true -> unreported_band ~cells
  | 0, false -> empty_band ~cells
  | count, true ->
      window_label ~style:(wakes_tint 0.65) ~cells
        (if ko then Printf.sprintf "예약 %d+" count else Printf.sprintf "%d+ wakes" count)
        (Printf.sprintf "%d+" count)
  | count, false ->
      window_label ~style:(wakes_tint 0.78) ~cells
        (if ko then Printf.sprintf "예약 %d" count else Printf.sprintf "%d wakes" count)
        (string_of_int count)

let wake_strip ~style slots =
  let cells = List.length slots in
  if cells = 0 then ""
  else if List.for_all (function
    | Next.Wakes_unknown -> true
    | Next.Wakes _ | Next.Wakes_with_unknown _ -> false) slots then
    unreported_band ~cells
  else if List.for_all (function
    | Next.Wakes n -> n <= 0
    | Next.Wakes_with_unknown _ | Next.Wakes_unknown -> false) slots then
    empty_band ~cells
  else
    let peak, min_pos =
      List.fold_left (fun (peak, min_pos) -> function
        | Next.Wakes count | Next.Wakes_with_unknown count when count > 0 ->
            max peak count, (match min_pos with None -> Some count | Some m -> Some (min m count))
        | Next.Wakes _ | Next.Wakes_with_unknown _ | Wakes_unknown -> peak, min_pos)
        (0, None) slots
    in
    let flat = match min_pos with Some m -> m = peak | None -> true in
    (* Keep wake strips calm while still showing green Oklab progression:
       uniform cadences draw a soft low sparkline, and varying counts step
       smoothly along the Wakes series ramp up to six-eighths height. *)
    let wake_level count =
      if flat then "\xe2\x96\x82" (* ▂ *)
      else
        let glyphs = [| "\xe2\x96\x81"; "\xe2\x96\x82"; "\xe2\x96\x83"; "\xe2\x96\x84"; "\xe2\x96\x85"; "\xe2\x96\x86" |] in
        let n = Array.length glyphs in
        let idx = min (n - 1) (((count * n + peak - 1) / max 1 peak) - 1) in
        glyphs.(max 0 idx)
    in
    let tint = Theme.series_tint Masc_tui_theme.Wakes in
    let tone = match style with
      | Keeper_wakes -> fun _ -> tint 0.7
      | Wake_counts ->
          fun count ->
            if flat then tint 0.48
            else tint (0.35 +. (0.65 *. (float_of_int count /. float_of_int (max 1 peak))))
    in
    let recede = Theme.recede () in
    Ansi.with_styled_runs ~capacity:(cells * 6) (fun emit ->
      List.iter (fun slot ->
        match slot with
        | Next.Wakes_unknown -> emit recede (Grid.strip_mark Grid.Strip_unknown)
        | Next.Wakes_with_unknown count when count <= 0 ->
            emit recede (Grid.strip_mark Grid.Strip_unknown)
        | Next.Wakes_with_unknown count | Wakes count ->
            if count <= 0 then emit recede (Grid.strip_mark Grid.Strip_empty)
            else
              let mark = match style with
                | Keeper_wakes -> Grid.strip_mark Grid.Strip_wake
                | Wake_counts -> wake_level count in
              emit (tone count) mark) slots)

type fleet_cells = { name : string; pulse : string; strip : string; due : string }

(* Readings shorter than [side_cells] are counted as unknown at the missing
   slot rather than raising, keeping fleet aggregation total. *)
let failed_count reading_arrays index =
  List.fold_left (fun (count, unknown) slots ->
    if index < Array.length slots then
      match slots.(index) with
      | Pulse.Half_hour_failed | Pulse.Half_hour_failed_and_ok -> count + 1, unknown
      | Pulse.Half_hour_unknown -> count, true
      | Pulse.Half_hour_quiet | Pulse.Half_hour_ok -> count, unknown
    else count, true) (0, false) reading_arrays

(* A grid with no band has no cells for the two maxima to scale, and the
   maximum over no cells is not a reading: there is no row to draw. *)
let fleet_cells ?(summarize_wakes = false) ~ko ~now ~(grid : Grid.t) ~wakes rows =
  if grid.side_cells <= 0 then None
  else
  let readings = List.map (fun row ->
    let pulse = Option.bind (runtime row) (fun row -> row.Decode.kr_recent_turns) in
    Pulse.half_hours ~now ~count:grid.side_cells pulse) rows in
  let reading_arrays = List.map Array.of_list readings in
  let counts = List.init grid.side_cells (failed_count reading_arrays) in
  let peak = List.fold_left (fun p (n, _) -> max p n) 0 counts in
  let pulse =
    if Pulse.nothing_read readings then history_unknown_label ~cells:grid.side_cells
    else
      let low_tint = Theme.series_tint Masc_tui_theme.Latency 0.55 in
      let bad = Theme.bad () and warn = Theme.warn () and recede = Theme.recede () in
      let fail_tone n =
        if peak > 1 && n * 3 >= peak * 2 then bad
        else if peak > 2 && n * 3 <= peak then low_tint
        else warn
      in
      (* Keep 1-row fleet failure sparklines light (1..2 top dot rows: ⠉ ⠋ ⠙ ⠛),
         matching Day_wall pure-fail cells and staying shape-disjoint from ok ⣀. *)
      let count_arr = Array.of_list counts in
      let scale_dots n = if peak > 1 && n * 2 > peak then 2 else 1 in
      let level_arr =
        Array.map (fun (n, _) -> if n > 0 then scale_dots n else 0) count_arr
      in
      Ansi.with_styled_runs ~capacity:(grid.side_cells * 6) (fun emit ->
        Array.iteri (fun i (n, unknown) ->
          if n > 0 then
            let h = level_arr.(i) in
            let left =
              if i > 0 && level_arr.(i - 1) > 0 then level_arr.(i - 1)
              else 1
            in
            emit (fail_tone n) (Masc_tui_braille.braille_pair_down ~left ~right:h)
          else emit recede (if unknown then Grid.strip_mark Grid.Strip_unknown else "·")) count_arr) in
  let active = List.filter (fun row -> match runtime row with
    | Some row -> not row.Decode.kr_paused | None -> true) rows in
  let future = match active with
    | [] -> List.init (Grid.strip_cells grid) (fun _ -> Next.Wakes 0)
    | _ :: _ -> Next.sum_wake_strips (List.map (fun row ->
        match runtime row with Some _ -> wakes row
        | None -> Next.unknown_strip ~ahead:(Grid.strip_cells grid - 1)) active) in
  let wake_peak = List.fold_left (fun p slot -> match slot with
    | Next.Wakes n -> max p n
    | Next.Wakes_with_unknown n -> max p n
    | Next.Wakes_unknown -> p) 0 future in
  let strip =
    if summarize_wakes then wake_summary ~ko future
    else wake_strip ~style:Wake_counts future
  in
  let pulse_max = if peak = 0 && List.exists snd counts then "?" else string_of_int peak in
  let wake_max = if wake_peak = 0 && List.exists (function
    | Next.Wakes_unknown | Next.Wakes_with_unknown _ -> true
    | Next.Wakes _ -> false) future then "?" else string_of_int wake_peak in
  (* The long name is taken when it fits the name column with its number, so
     neither language loses the number to the column's edge. *)
  let name =
    let long = (if ko then "전체 실패/30분 최대 " else "fleet fail/30m max ") ^ pulse_max in
    if Layout.display_width long <= grid.name_cells then long
    else (if ko then "전체 최대 " else "fleet max ") ^ pulse_max in
  Some { name
  ; pulse; strip
  ; due =
      let label = (if ko then "최대" else "max ") ^ wake_max in
      if Layout.display_width label <= Grid.due_cells then label
      else
        let compact = "\xe2\x86\x91" ^ wake_max in
        if Layout.display_width compact <= Grid.due_cells then compact
        else Layout.compact_count wake_peak }

let selected_summary ~ko ~now ~activity_cell ~next_run ~recurrence ~memory row =
  let say korean english = if ko then korean else english in
  let observed = runtime row in
  let verdict = Grid.verdict ~now observed in
  let age = Option.bind row.Model.last_activity_at (fun since -> Layout.age_text ~now ~since) in
  let since = match verdict, observed with
    | Grid.Failing _, Some runtime ->
        Some (match runtime.Decode.kr_failing_since with
          | Some at when Float.is_finite at && at <= now ->
              say "시작 " "since " ^ Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_minute ~now at
          | Some _ | None -> say "시작 ?" "since ?")
    | Grid.Failing _, None -> Some (say "시작 ?" "since ?")
    | (Grid.Paused | Grid.Offline _ | Grid.Recovered | Grid.Sound | Grid.Other), (Some _ | None) -> None in
  let next = match next_run with
    | Next.Scheduled_at at ->
        Some (if Float.is_finite at then
          "◷ " ^ Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_minute ~now at
          else "◷ ?")
    | Next.No_schedule | Next.Late_since _ | Next.Held_current _ | Next.Held_as_of _
    | Next.Not_before _ | Next.Unknown ->
        Option.map (fun (cell : Masc_tui_keeper_axis_cell.t) -> cell.text)
          (Next.cell ~ko ~now next_run) in
  let next = Option.map (fun text -> text ^ (match recurrence with
    | Some (Schedule_domain.Interval { interval_sec }) ->
        say " 주기 " " every " ^ Masc_tui_value.Interval.text interval_sec
    | Some (Schedule_domain.One_shot as recurrence)
    | Some (Schedule_domain.Daily _ as recurrence)
    | Some (Schedule_domain.Cron _ as recurrence) -> " " ^ clean (Schedule_domain.recurrence_summary recurrence)
    | None -> "")) next in
  let lag = match memory with
    | Memory.Row { lag = Memory.Lag n; _ } ->
        if n > 0 then Some (say "지연 " "lag " ^ string_of_int n) else None
    | Memory.Row { lag = Memory.Lag_unmeasured; _ } | Memory.Unknown -> Some (say "지연 ?" "lag ?")
    | Memory.Refused _ -> Some (say "지연 !" "lag !")
    | Memory.No_row -> None in
  let head = match verdict, observed with
    | Grid.Failing _, Some row ->
        (match row.Decode.kr_runtime_path_rest with
         | Ok (Some (Decode.Path_rest_serving path)) -> Some ("▹ " ^ clean path.runtime_id)
         | Ok (Some (Decode.Path_rest_resting path)) ->
             Some (Masc_tui_value.Mark.(glyph Waiting) ^ say " 대기 " " wait " ^ clean path.runtime_id)
         | Error _ | Ok None -> Some "▹ ?")
    | (Grid.Paused | Grid.Offline _ | Grid.Recovered | Grid.Sound | Grid.Other), (Some _ | None)
    | Grid.Failing _, None -> None in
  let first = clean (name row) ^ " " ^ activity_cell
    ^ (match age with Some age -> " " ^ age | None -> "") in
  String.concat " · " (first :: List.filter_map Fun.id [since; next; lag; head])
