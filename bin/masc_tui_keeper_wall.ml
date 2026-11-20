module Braille = Masc_tui_braille
module Pulse_wire = Masc.Keeper_turn_pulse
module Pulse = Masc_tui_keeper_pulse
module Grid = Masc_tui_keeper_grid
module Layout = Masc_tui_message_layout
module Ansi = Masc_tui_ansi.Ansi
module Theme = Masc_tui_ansi.Theme
module Terminal_text = Masc_tui_ansi.Terminal_text

let day_slots = Pulse_wire.window_seconds / Pulse_wire.slot_seconds

let count_text = function
  | Pulse.Exact n -> string_of_int n
  | Pulse.At_least n -> "≥" ^ string_of_int n
  | Pulse.Count_unknown -> "?"

let pulse = function
  | Some runtime -> runtime.Masc.Tui_decode.kr_recent_turns
  | None -> None

let tallies ~now ~count runtime = Pulse.half_hour_tallies ~now ~count (pulse runtime)

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

let ok_activity_level total =
  if total <= 2 then 1
  else if total <= 6 then 2
  else 3

let fail_activity_level total =
  if total <= 1 then 2
  else if total <= 4 then 3
  else 4

type slot_class =
  | Class_quiet_or_unknown
  | Class_rested
  | Class_ok of int
  | Class_failed of int
  | Class_mixed of int

let classify_tally = function
  | Pulse.Slot_tally_unknown -> Class_quiet_or_unknown
  | Pulse.Slot_tally_measured { Pulse_wire.ok; rested; failed } ->
      let bad = failed + rested in
      if ok + bad = 0 then Class_quiet_or_unknown
      else if bad = 0 then Class_ok (ok_activity_level ok)
      else if ok = 0 && failed > 0 then Class_failed (fail_activity_level failed)
      else if ok > 0 then Class_mixed (ok_activity_level ok)
      else Class_rested

(* Partition Braille shapes 100% disjointly by turn outcome so NO_COLOR
   preserves every distinction while consecutive pure-ok or pure-failed slots
   connect smoothly like btop C0..C15 waves:
   - quiet = ·, unread = ─
   - pure ok: bottom-aligned (dots 1,4 clear; dot 8 set)
   - rested only: single bottom-left dot ⠄ (dot 8 clear)
   - mixed: asymmetric left 1..3 + right 4 (dot 1 clear, dot 4 set)
   - pure fail: top-hanging down-Braille ⠙..⣿ (dot 1 set, dot 4 set) *)
let tally_marks slot_tallies =
  let arr = Array.of_list slot_tallies in
  let n = Array.length arr in
  let classes = Array.map classify_tally arr in
  let ok_tint = Theme.series_tint Masc_tui_theme.Completion in
  let warm_tint = Theme.warm_tint () in
  let thermal_tint = Theme.thermal_tint () in
  let buf = Buffer.create (n * 16) in
  for i = 0 to n - 1 do
    match arr.(i) with
    | Pulse.Slot_tally_unknown ->
        Buffer.add_string buf
          (Theme.recede () ^ Masc_tui_keeper_mark.grid_unknown_range_mark ^ Ansi.reset)
    | Pulse.Slot_tally_measured _ -> (
        match classes.(i) with
        | Class_quiet_or_unknown ->
            Buffer.add_string buf
              (Theme.recede () ^ Masc_tui_keeper_mark.grid_dot_mark ^ Ansi.reset)
        | Class_ok h ->
            let left =
              if i > 0 then
                match classes.(i - 1) with
                | Class_ok prev_h -> max 1 ((prev_h + h) / 2)
                | Class_quiet_or_unknown | Class_rested | Class_failed _
                | Class_mixed _ ->
                    if h >= 2 then h - 1 else 1
              else if h >= 2 then h - 1
              else 1
            in
            let glyph = Braille.braille_pair ~left ~right:h in
            let tone = ok_tint (float_of_int h /. 3.0) in
            Buffer.add_string buf (tone ^ glyph ^ Ansi.reset)
        | Class_failed h ->
            let left =
              if i > 0 then
                match classes.(i - 1) with
                | Class_failed prev_h -> max 1 ((prev_h + h) / 2)
                | Class_quiet_or_unknown | Class_rested | Class_ok _
                | Class_mixed _ ->
                    max 1 (h - 1)
              else max 1 (h - 1)
            in
            let glyph = Braille.braille_pair_down ~left ~right:h in
            let tone = warm_tint (float_of_int (h - 1) /. 3.0) in
            Buffer.add_string buf (tone ^ glyph ^ Ansi.reset)
        | Class_mixed ok_h ->
            let glyph = Braille.braille_pair ~left:ok_h ~right:4 in
            let tone = thermal_tint 0.62 in
            Buffer.add_string buf (tone ^ glyph ^ Ansi.reset)
        | Class_rested ->
            let glyph = Braille.braille_pair ~left:1 ~right:0 in
            Buffer.add_string buf (Theme.warn () ^ glyph ^ Ansi.reset))
  done;
  Buffer.contents buf

(* A band nothing was read for says so once in the band's width, as the roster's
   history column does; a partly read band keeps one mark per half hour. *)
let band ~count readings marks_of =
  if Pulse.nothing_read readings then Masc_tui_keeper_strip.history_unknown_label ~cells:count
  else marks_of ()

let row ?(selected = false) ~ko:_ ~cols ~now ~name runtime =
  let name_cells, count = dimensions cols in
  let slot_tallies = tallies ~now ~count runtime in
  let hours = List.map Pulse.half_hour_of_tally slot_tallies in
  (* The row mark every view draws for this verdict (RFC
     tui-one-screen-grammar §7.2); the wall does not mark a recovery. *)
  let mark =
    Grid.mark Masc_tui_keeper_list_model.Day_wall (Grid.verdict ~now runtime) in
  prefix ~selected name_cells mark name ^ band ~count [ hours ] (fun () -> tally_marks slot_tallies)
  ^ Theme.recede () ^ " │ " ^ Ansi.reset
  ^ Printf.sprintf "%s/%d" (count_text (Pulse.failure_count hours)) count

let legend_row ~ko ~cols =
  let say k e = if ko then k else e in
  let dim s = Theme.recede () ^ s ^ Ansi.reset in
  let sample tone glyph label =
    tone ^ glyph ^ Ansi.reset ^ dim (" " ^ label)
  in
  let ok_tint = Theme.series_tint Masc_tui_theme.Completion in
  let warm_tint = Theme.warm_tint () in
  let thermal_tint = Theme.thermal_tint () in
  let raw =
    "  "
    ^ sample (Theme.recede ()) Masc_tui_keeper_mark.grid_dot_mark (say "무활동" "quiet")
    ^ "  " ^ sample (Theme.recede ()) Masc_tui_keeper_mark.grid_unknown_range_mark (say "미기록" "unread")
    ^ "  " ^ sample (ok_tint 0.85) (Braille.braille_pair ~left:2 ~right:3) (say "정상(↑)" "ok(up)")
    ^ "  " ^ sample (warm_tint 0.90) (Braille.braille_pair_down ~left:2 ~right:4) (say "실패(↓)" "fail(down)")
    ^ "  " ^ sample (thermal_tint 0.62) (Braille.braille_pair ~left:2 ~right:4) (say "혼재" "mixed")
    ^ "  " ^ sample (Theme.warn ()) (Braille.braille_pair ~left:1 ~right:0) (say "휴식" "rest")
  in
  Layout.truncate_end (max 0 cols) raw ^ Ansi.reset

let scale_wave_level ~peak value =
  if value <= 0 || peak <= 0 then None
  else
    let scaled = int_of_float (Float.ceil (float_of_int value /. float_of_int peak *. 8.0)) in
    Some (max 1 (min 8 scaled))

let smooth_wave_pairs (levels : int option array) =
  let n = Array.length levels in
  List.init n (fun i ->
    match levels.(i) with
    | None -> (0, 0)
    | Some v ->
        let left =
          match (if i > 0 then levels.(i - 1) else None) with
          | Some p -> max 1 ((p + v) / 2)
          | None -> max 1 (v / 2)
        in
        (left, v))

let fleet_rows ~ko ~cols ~now runtimes =
  let say k e = if ko then k else e in
  let name_cells, count = dimensions cols in
  let all_tallies = List.map (tallies ~now ~count) runtimes in
  let all_hours = List.map (List.map Pulse.half_hour_of_tally) all_tallies in
  let slot_agg =
    Array.init count (fun position ->
      let slot_entries =
        List.map
          (fun entries -> Option.value ~default:Pulse.Slot_tally_unknown (List.nth_opt entries position))
          all_tallies
      in
      let hours = List.map Pulse.half_hour_of_tally slot_entries in
      let ok_sum, bad_sum =
        List.fold_left
          (fun (ok_acc, bad_acc) -> function
            | Pulse.Slot_tally_measured { Pulse_wire.ok; rested; failed } ->
                (ok_acc + ok, bad_acc + failed + rested)
            | Pulse.Slot_tally_unknown -> (ok_acc, bad_acc))
          (0, 0) slot_entries
      in
      (Pulse.failure_count hours, ok_sum, bad_sum))
  in
  let peak_fail =
    Pulse.peak_failure_count
      (Array.to_list (Array.map (fun (fc, _, _) -> fc) slot_agg))
  in
  let fit_row line = Layout.truncate_end (max 0 cols) line ^ Ansi.reset in
  if Pulse.nothing_read all_hours then
    let row0 =
      prefix name_cells " " (say "전체" "fleet")
      ^ Masc_tui_keeper_strip.history_unknown_label ~cells:count
      ^ Theme.recede () ^ (if ko then " │ 최대 " else " │ peak ") ^ Ansi.reset
      ^ count_text peak_fail
    in
    [ fit_row row0; legend_row ~ko ~cols ]
  else
    let peak_ok =
      Array.fold_left (fun peak (_, ok_sum, _) -> max peak ok_sum) 0 slot_agg
    in
    let peak_bad =
      Array.fold_left (fun peak (_, _, bad_sum) -> max peak bad_sum) 0 slot_agg
    in
    let ok_levels =
      Array.map (fun (_, ok_sum, _) -> scale_wave_level ~peak:peak_ok ok_sum) slot_agg
    in
    let bad_levels =
      Array.map (fun (_, _, bad_sum) -> scale_wave_level ~peak:peak_bad bad_sum) slot_agg
    in
    let up_pairs = smooth_wave_pairs ok_levels in
    let down_pairs = smooth_wave_pairs bad_levels in
    let ok_tint = Theme.series_tint Masc_tui_theme.Completion in
    let warm_tint = Theme.warm_tint () in
    let up_top =
      match Braille.braille_curve_rows ~down:false ~tint:ok_tint ~rows:2 up_pairs with
      | top :: _ -> top
      | [] -> ""
    in
    let dn_base, dn_bot =
      match Braille.braille_curve_rows ~down:true ~tint:warm_tint ~rows:2 down_pairs with
      | top :: bot :: _ -> (top, bot)
      | [ one ] -> (one, "")
      | [] -> ("", "")
    in
    (* Build the lower rising row explicitly per cell so quiet/unread zero
       columns with no downward wave below them keep · or ─ baseline markers
       while active columns render Braille bottom cells identically to row 0. *)
    let up_arr = Array.of_list up_pairs in
    let dn_arr = Array.of_list down_pairs in
    let base_buf = Buffer.create (count * 12) in
    let ok_base_tone = ok_tint 0.0 in
    for i = 0 to count - 1 do
      let l, r = up_arr.(i) in
      let dl, dr = dn_arr.(i) in
      if l = 0 && r = 0 && dl = 0 && dr = 0 then
        let fc, _, _ = slot_agg.(i) in
        match fc with
        | Pulse.Count_unknown ->
            Buffer.add_string base_buf
              (Theme.recede () ^ Masc_tui_keeper_mark.grid_unknown_range_mark ^ Ansi.reset)
        | Pulse.Exact _ | Pulse.At_least _ ->
            Buffer.add_string base_buf
              (Theme.recede () ^ Masc_tui_keeper_mark.grid_dot_mark ^ Ansi.reset)
      else
        let glyph = Braille.braille_pair ~left:l ~right:r in
        if l = 0 && r = 0 then Buffer.add_string base_buf glyph
        else Buffer.add_string base_buf (ok_base_tone ^ glyph ^ Ansi.reset)
    done;
    let up_base = Buffer.contents base_buf in
    let ok_peak_text =
      if peak_ok <= 0 then Masc_tui_theme.Glyph.no_value else string_of_int peak_ok
    in
    let bad_peak_text =
      if peak_bad <= 0 then Masc_tui_theme.Glyph.no_value else string_of_int peak_bad
    in
    let dim_rule s = Theme.recede () ^ " │ " ^ s ^ Ansi.reset in
    [ fit_row
        (prefix name_cells " " (say "전체" "fleet")
         ^ up_top ^ dim_rule ("↑" ^ say "정상 " "ok " ^ ok_peak_text))
    ; fit_row (prefix name_cells " " "" ^ up_base ^ dim_rule ("↑24h"))
    ; fit_row
        (prefix name_cells " " "" ^ dn_base ^ dim_rule ("↓" ^ say "실패 " "fail " ^ bad_peak_text))
    ; fit_row
        (prefix name_cells " " ""
         ^ dn_bot ^ Theme.recede () ^ (if ko then " │ 최대 " else " │ peak ") ^ Ansi.reset
         ^ count_text peak_fail)
    ; legend_row ~ko ~cols
    ]
