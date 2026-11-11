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
  let count = max 0 (min day_slots (cols - Grid.gutter_cells - name - 1 - 10)) in
  name, count

let prefix name_cells mark name =
  "▌ " ^ mark ^ " " ^ Layout.fit_width (Terminal_text.single_line name) name_cells ^ " "

let header ~cols ~now =
  let name, count = dimensions cols in
  let start = Masc.Keeper_turn_pulse.slot_start now - ((count - 1) * Masc.Keeper_turn_pulse.slot_seconds) in
  let ruler = Bytes.make count ' ' in
  let first_tick = if (Unix.localtime (float_of_int start)).Unix.tm_min = 0 then 0 else 1 in
  let rec ticks position =
    if position < count then begin
      let tm = Unix.localtime (float_of_int (start + position * Masc.Keeper_turn_pulse.slot_seconds)) in
      let label = Printf.sprintf "%02d:00" tm.Unix.tm_hour in
      Bytes.blit_string label 0 ruler position (min (String.length label) (count - position));
      ticks (position + 12)
    end in
  ticks first_tick;
  if count >= 3 then Bytes.blit_string "now" 0 ruler (count - 3) 3;
  prefix name " " "keeper" ^ Bytes.to_string ruler ^ "┃ fail"

let marks hours =
  String.concat "" (List.map (fun hour ->
    let tone = match hour with
      | Pulse.Half_hour_failed | Pulse.Half_hour_failed_and_ok -> Theme.warn ()
      | Pulse.Half_hour_ok -> Theme.ok ()
      | Pulse.Half_hour_quiet | Pulse.Half_hour_unknown -> Theme.recede () in
    tone ^ Pulse.half_hour_mark hour ^ Ansi.reset) hours)

(* A band nothing was read for says so once in the band's width, as the roster's
   history column does; a partly read band keeps one mark per half hour. *)
let band ~ko ~count readings marks_of =
  if Pulse.nothing_read readings then Masc_tui_keeper_strip.history_unknown_label ~ko ~cells:count
  else marks_of ()

let row ~ko ~cols ~now ~name runtime =
  let name_cells, count = dimensions cols in
  let hours = slots ~now ~count runtime in
  let mark = match Grid.verdict ~now runtime with
    | Grid.Failing _ -> "!"
    | Grid.Paused -> "○"
    | Grid.Recovered | Grid.Sound | Grid.Other -> "●" in
  prefix name_cells mark name ^ band ~ko ~count [ hours ] (fun () -> marks hours) ^ "┃ "
  ^ Printf.sprintf "%s/%d" (count_text (Pulse.failure_count hours)) count

let fleet ~ko ~cols ~now runtimes =
  let name_cells, count = dimensions cols in
  let all = List.map (slots ~now ~count) runtimes in
  let counts = List.init count (fun position ->
    Pulse.failure_count (List.map (fun hours ->
      match List.nth_opt hours position with Some hour -> hour | None -> Pulse.Half_hour_unknown) all)) in
  let peak = Pulse.peak_failure_count counts in
  prefix name_cells " " "fleet"
  ^ band ~ko ~count all (fun () ->
      String.concat "" (List.map (function
        | Pulse.Count_unknown -> Pulse.half_hour_mark Pulse.Half_hour_unknown
        | Pulse.Exact 0 -> Pulse.half_hour_mark Pulse.Half_hour_quiet
        | (Pulse.Exact n | Pulse.At_least n) ->
            Grid.level_glyph ~peak:(Pulse.failure_lower_bound peak) n) counts))
  ^ "┃ peak " ^ count_text peak
