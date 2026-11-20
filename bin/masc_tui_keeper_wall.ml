module Pulse = Masc_tui_keeper_pulse
module Grid = Masc_tui_keeper_grid
module Layout = Masc_tui_message_layout
module Ansi = Masc_tui_ansi.Ansi
module Theme = Masc_tui_ansi.Theme
module Terminal_text = Masc_tui_ansi.Terminal_text

let day_slots = Masc.Keeper_turn_pulse.window_seconds / Masc.Keeper_turn_pulse.slot_seconds

let count_text = function
  | Pulse.Exact n -> string_of_int n
  | Pulse.At_least n -> "≥" ^ string_of_int n
  | Pulse.Count_unknown -> "?"

let pulse = function
  | Some runtime -> runtime.Masc.Tui_decode.kr_recent_turns
  | None -> None

let slots ~now ~count runtime = Pulse.half_hours ~now ~count (pulse runtime)

type group = Failing | Other | Sound

let group ~now runtime =
  match runtime with
  | Some runtime when runtime.Masc.Tui_decode.kr_paused -> Other
  | Some _ | None -> match Grid.verdict ~now runtime with
  | Grid.Failing _ -> Failing
  | Grid.Recovered -> Other
  | Grid.Paused | Grid.Other -> Other
  | Grid.Sound ->
      (match pulse runtime with
       | None -> Other
       | Some _ ->
           (* Classification uses observed failures, not an exact total. *)
           if Pulse.failure_lower_bound (Pulse.failure_count (slots ~now ~count:day_slots runtime)) > 0
           then Other else Sound)

let rank = function Failing -> 0 | Other -> 1 | Sound -> 2

let dimensions cols =
  let name = (Grid.layout ~cols).name_cells in
  let count = max 0 (min day_slots (cols - Grid.gutter_cells - name - 1 - 12)) in
  name, count

let prefix ?(selected = false) name_cells mark name =
  (if selected then "› " else "  ") ^ mark ^ " "
  ^ Layout.fit_width (Terminal_text.single_line name) name_cells ^ " "

let header ~ko ~cols ~now =
  let name, count = dimensions cols in
  let start = Masc.Keeper_turn_pulse.slot_start now - ((count - 1) * Masc.Keeper_turn_pulse.slot_seconds) in
  let ruler = Bytes.make count ' ' in
  let now_word = if ko then "현재" else "now" in
  let now_cells = Layout.display_width now_word in
  (* Leave at least one blank cell before [now_word] so an ASCII hour label is
     never sliced in half at the right edge of the ruler. *)
  let tick_limit = max 0 (count - now_cells - 1) in
  let mark_at position =
    Masc_tui_value.Instant.axis_hour
      (float_of_int (start + position * Masc.Keeper_turn_pulse.slot_seconds))
  in
  (* Slots start on the half hour, so the first hour starts at the first or
     the second slot. *)
  let first_tick = match mark_at 0 with Some _ -> 0 | None -> 1 in
  let rec ticks position =
    if position < tick_limit then begin
      (match mark_at position with
       | Some label when position + String.length label <= tick_limit ->
           Bytes.blit_string label 0 ruler position (String.length label)
       | Some _ | None -> ());
      ticks (position + 12)
    end in
  ticks first_tick;
  (* The ruler holds ASCII hour labels, one byte a cell; the now word is laid
     after the cells it takes, so a Korean word keeps the ruler's width. *)
  let ruler = Bytes.to_string ruler in
  let ruler =
    if count >= now_cells then String.sub ruler 0 (count - now_cells) ^ now_word else ruler in
  Theme.recede ()
  ^ prefix name " " (Masc_tui_keeper_mark.grid_column_word ~ko Masc_tui_keeper_mark.Keeper_column)
  ^ ruler ^ (if ko then " │ 실패" else " │ fail")
  ^ Ansi.reset

let marks hours =
  String.concat "" (List.map (fun hour ->
    let tone = match hour with
      | Pulse.Half_hour_failed -> Theme.bad ()
      | Pulse.Half_hour_failed_and_ok -> Theme.warn ()
      | Pulse.Half_hour_ok -> Theme.ok ()
      | Pulse.Half_hour_quiet | Pulse.Half_hour_unknown -> Theme.recede () in
    let glyph = match hour with
      | Pulse.Half_hour_unknown -> Masc_tui_keeper_mark.grid_unknown_range_mark
      | Pulse.Half_hour_failed | Pulse.Half_hour_failed_and_ok
      | Pulse.Half_hour_ok | Pulse.Half_hour_quiet -> Pulse.half_hour_mark hour in
    tone ^ glyph ^ Ansi.reset) hours)

(* A band nothing was read for says so once in the band's width, as the roster's
   history column does; a partly read band keeps one mark per half hour. *)
let band ~count readings marks_of =
  if Pulse.nothing_read readings then Masc_tui_keeper_strip.history_unknown_label ~cells:count
  else marks_of ()

let row ?(selected = false) ~ko:_ ~cols ~now ~name runtime =
  let name_cells, count = dimensions cols in
  let hours = slots ~now ~count runtime in
  (* The row mark every view draws for this verdict (RFC
     tui-one-screen-grammar §7.2); the wall does not mark a recovery. *)
  let mark =
    Grid.mark Masc_tui_keeper_list_model.Day_wall (Grid.verdict ~now runtime) in
  prefix ~selected name_cells mark name ^ band ~count [ hours ] (fun () -> marks hours)
  ^ Theme.recede () ^ " │ " ^ Ansi.reset
  ^ Printf.sprintf "%s/%d" (count_text (Pulse.failure_count hours)) count

let fleet ~ko ~cols ~now runtimes =
  let name_cells, count = dimensions cols in
  let all = List.map (slots ~now ~count) runtimes in
  let counts = List.init count (fun position ->
    Pulse.failure_count (List.map (fun hours ->
      match List.nth_opt hours position with Some hour -> hour | None -> Pulse.Half_hour_unknown) all)) in
  let peak = Pulse.peak_failure_count counts in
  let peak_lower = Pulse.failure_lower_bound peak in
  let low_tint = Theme.series_tint Masc_tui_theme.Latency 0.55 in
  let fail_tone n =
    if peak_lower > 1 && n * 3 >= peak_lower * 2 then Theme.bad ()
    else if peak_lower > 2 && n * 3 <= peak_lower then low_tint
    else Theme.warn ()
  in
  prefix name_cells " " (if ko then "전체" else "fleet")
  ^ band ~count all (fun () ->
      String.concat "" (List.map (function
        | Pulse.Count_unknown ->
            Theme.recede () ^ Masc_tui_keeper_mark.grid_unknown_range_mark ^ Ansi.reset
        | Pulse.Exact 0 ->
            Theme.recede () ^ Pulse.half_hour_mark Pulse.Half_hour_quiet ^ Ansi.reset
        | (Pulse.Exact n | Pulse.At_least n) ->
            fail_tone n ^ Grid.level_glyph ~peak:peak_lower n ^ Ansi.reset) counts))
  ^ Theme.recede () ^ (if ko then " │ 최대 " else " │ peak ") ^ Ansi.reset ^ count_text peak
