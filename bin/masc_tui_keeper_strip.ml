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

let header ~ko ~now ~cells ~view ~selected ~age rows =
  let say korean english = if ko then korean else english in
  let unknown = say "미확인" "unknown" in
  (* The age words name the bound each bucket is cut at, as [bucket] reads
     it off [Model.age]. *)
  let groups = match view with
    | Model.By_age ->
        [Fresh, "█", say "3시간 안" "fresh", Theme.info ();
         Today, "▆", say "하루 안" "today", Ansi.reset;
         Cooling, "▃", say "사흘 안" "cooling", Theme.recede ();
         Dormant, "▁", say "더 오래" "dormant", Theme.recede ();
         Unknown, "?", unknown, Theme.recede ()]
    | Model.(Plain | By_state | By_cause | By_time | By_memory | By_runtime | Day_wall) ->
        [Failures, "!", say "실패" "failing", Theme.warn ();
         Recoveries, "✓", say "복구" "recovered", Theme.ok ();
         Sound, "●", say "정상" "ok", Theme.ok ();
         Paused, "○", say "일시정지" "paused", Theme.recede ();
         Unknown, "?", unknown, Theme.recede ()] in
  let readings = List.map (fun row -> row, bucket ~now ~age view row) rows in
  let groups = List.filter_map (fun (key, mark, word, style) ->
    let members = List.filter_map (fun (row, at) -> if at = key then Some row else None) readings in
    match members with [] -> None | _ :: _ -> Some (key, mark, word, style, members)) groups in
  let label long (_, mark, word, _, members) =
    if not long then mark ^ string_of_int (List.length members)
    else if ko then Printf.sprintf "%s %s %d" mark word (List.length members)
    else Printf.sprintf "%s %d %s" mark (List.length members) word in
  let sep_w = 2 * max 0 (List.length groups - 1) in
  let base_w long =
    sep_w + List.fold_left (fun n g -> n + Layout.display_width (label long g)) 0 groups in
  let full_marks_w =
    List.fold_left (fun n (_, _, _, _, members) -> n + 1 + List.length members) 0 groups in
  let long = base_w true + full_marks_w <= cells in
  let group_count = List.length groups in
  let mark_budgets =
    let avail = max 0 (cells - base_w long) in
    if full_marks_w <= avail then
      List.map (fun (_, _, _, _, members) -> 1 + List.length members) groups
    else
      let caps =
        Array.of_list (List.map (fun (_, _, _, _, members) -> 1 + List.length members) groups)
      in
      let alloc = Array.make group_count 0 in
      let rem = ref avail in
      let progress = ref true in
      while !rem > 0 && !progress do
        progress := false;
        for i = 0 to group_count - 1 do
          if !rem > 0 && alloc.(i) < caps.(i) then (
            alloc.(i) <- alloc.(i) + 1;
            decr rem;
            progress := true)
        done
      done;
      Array.to_list alloc
  in
  let draw_mark key style row =
    let mark, tone = match key with
      | Paused -> "·", Theme.recede ()
      | Failures ->
          (match Grid.verdict ~now (runtime row) with
           | Grid.Failing { resting = true } -> "▫", Theme.recede ()
           | Grid.Failing { resting = false } | Grid.Paused | Grid.Recovered | Grid.Sound | Grid.Other -> "▪", style)
      | Dormant -> if odd_dormant row then "▪", Theme.warn () else "▫", style
      | Unknown -> "?", Theme.recede ()
      | Recoveries | Sound | Fresh | Today | Cooling -> "▪", style in
    tone ^ (if selected = Some (name row) then Ansi.bold else "") ^ mark ^ Ansi.reset
  in
  let take_with_selected count members =
    let rec take n acc = function
      | [] -> List.rev acc
      | _ when n <= 0 -> List.rev acc
      | x :: xs -> take (n - 1) (x :: acc) xs
    in
    let prefix = take count [] members in
    match selected with
    | None -> prefix
    | Some sel ->
      if List.exists (fun r -> String.equal (name r) sel) prefix then prefix
      else
        (match List.find_opt (fun r -> String.equal (name r) sel) members with
         | None -> prefix
         | Some sel_row ->
           (match List.rev prefix with
            | [] -> [sel_row]
            | _ :: rev_init -> List.rev (sel_row :: rev_init)))
  in
  let draw budget ((key, _, _, style, members) as group) =
    let count = List.length members in
    let lbl = style ^ label long group ^ Ansi.reset in
    if budget >= 1 + count then
      lbl ^ " " ^ String.concat "" (List.map (draw_mark key style) members)
    else
      let mark_cols = budget - 1 in
      let max_suffix_w = 1 + String.length (string_of_int count) in
      if mark_cols >= 1 + max_suffix_w then
        let shown0 = mark_cols - max_suffix_w in
        let shown =
          if shown0 + 1 < count
             && shown0 + 1 + 1 + String.length (string_of_int (count - shown0 - 1)) <= mark_cols
          then shown0 + 1
          else shown0
        in
        let omitted = count - shown in
        let visible_members = take_with_selected shown members in
        let marks_str = String.concat "" (List.map (draw_mark key style) visible_members) in
        let suffix = Theme.recede () ^ "+" ^ string_of_int omitted ^ Ansi.reset in
        lbl ^ " " ^ marks_str ^ suffix
      else
        lbl
  in
  String.concat "  " (List.map2 draw mark_budgets groups)

type wake_style = Keeper_wakes of { paused : bool } | Wake_counts

let window_label ~cells full narrow =
  Theme.recede ()
  ^ Layout.fit_width (if Layout.display_width full <= cells then full else narrow) cells
  ^ Ansi.reset

(* One label in place of a half-hour band that has nothing read to draw, in the
   band's width; [?] when the label does not fit. *)
let history_unknown_label ~ko ~cells =
  window_label ~cells (if ko then "기록 미확인" else "history unknown") "?"

let wake_summary ~ko slots =
  let cells = List.length slots in
  let known, unknown = List.fold_left (fun (known, unknown) -> function
    | Next.Wakes count -> known + max 0 count, unknown
    | Next.Wakes_with_unknown count -> known + max 0 count, true
    | Next.Wakes_unknown -> known, true) (0, false) slots in
  let full, narrow = match known, unknown with
    | 0, true -> (if ko then "일정 미확인" else "schedule unknown"), "?"
    | 0, false -> (if ko then "구간 내 예약 없음" else "no runs in window"), "-"
    | count, true ->
        (if ko then Printf.sprintf "%d회 확인 · 일부 미확인" count
         else Printf.sprintf "%d known · partial" count), Printf.sprintf "? %d+" count
    | count, false ->
        (if ko then Printf.sprintf "%d회 예약 확인" count
         else Printf.sprintf "%d known wakes" count), string_of_int count in
  if cells = 0 then "" else window_label ~cells full narrow

let wake_strip ~ko ~style slots =
  let cells = List.length slots in
  let label = window_label ~cells in
  if cells = 0 then ""
  else if List.for_all (function
    | Next.Wakes_unknown -> true
    | Next.Wakes _ | Next.Wakes_with_unknown _ -> false) slots then
    label (if ko then "일정 미확인" else "schedule unknown") "?"
  else if List.for_all (function
    | Next.Wakes n -> n <= 0
    | Next.Wakes_with_unknown _ | Next.Wakes_unknown -> false) slots then
    label (if ko then "구간 내 예약 없음" else "no runs in window") "-"
  else
    let peak = List.fold_left (fun peak -> function
      | Next.Wakes count -> max peak count
      | Next.Wakes_with_unknown count -> max peak count
      | Wakes_unknown -> peak) 0 slots in
    String.concat "" (List.mapi (fun index slot ->
      let quiet cell = Theme.recede () ^ Grid.strip_mark cell ^ Ansi.reset in
      match slot with
      | Next.Wakes_unknown -> quiet Grid.Strip_unknown
      | Next.Wakes_with_unknown count when count <= 0 -> quiet Grid.Strip_unknown
      | Next.Wakes_with_unknown count | Wakes count ->
          if count <= 0 then quiet Grid.Strip_empty else
          let tone, mark = match style with
            | Keeper_wakes { paused } ->
                (if paused then Theme.recede () else Theme.info ()), Grid.strip_mark Grid.Strip_wake
            | Wake_counts -> Theme.info (), Grid.level_glyph ~peak count in
          (if index = 0 then Ansi.bold else "") ^ tone ^ mark ^ Ansi.reset) slots)

type fleet_cells = { name : string; pulse : string; strip : string; due : string }

let failed_count readings index =
  List.fold_left (fun (count, unknown) slots ->
    match List.nth slots index with
    | Pulse.Half_hour_failed | Pulse.Half_hour_failed_and_ok -> count + 1, unknown
    | Pulse.Half_hour_unknown -> count, true
    | Pulse.Half_hour_quiet | Pulse.Half_hour_ok -> count, unknown) (0, false) readings

(* A grid with no band has no cells for the two maxima to scale, and the
   maximum over no cells is not a reading: there is no row to draw. *)
let fleet_cells ~ko ~now ~(grid : Grid.t) ~wakes rows =
  if grid.side_cells <= 0 then None
  else
  let readings = List.map (fun row ->
    let pulse = Option.bind (runtime row) (fun row -> row.Decode.kr_recent_turns) in
    Pulse.half_hours ~now ~count:grid.side_cells pulse) rows in
  let counts = List.init grid.side_cells (failed_count readings) in
  let peak = List.fold_left (fun p (n, _) -> max p n) 0 counts in
  let pulse =
    if Pulse.nothing_read readings then history_unknown_label ~ko ~cells:grid.side_cells
    else String.concat "" (List.map (fun (n, unknown) ->
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
    | Next.Wakes n -> max p n
    | Next.Wakes_with_unknown n -> max p n
    | Next.Wakes_unknown -> p) 0 future in
  let strip = wake_strip ~ko ~style:Wake_counts future in
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
  ; due = let label = (if ko then "최대" else "max ") ^ wake_max in
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
