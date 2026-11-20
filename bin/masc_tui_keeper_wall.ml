module Braille = Masc_tui_braille
module Card = Masc_tui_card
module Chart = Masc_tui_chart
module Doc = Masc_tui_doc
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

let scale_wave_level ~levels ~peak value =
  if value <= 0 || peak <= 0 || levels <= 0 then None
  else
    let scaled =
      int_of_float
        (Float.ceil (float_of_int value /. float_of_int peak *. float_of_int levels))
    in
    Some (max 1 (min levels scaled))

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

let dot_meter_summary_lines ~ko ~cells ~total_ok ~total_bad ~peak_ok ~peak_bad
    ~active_slots ~slot_count ~tail_note =
  let say k e = if ko then k else e in
  let total_all = max 1 (total_ok + total_bad) in
  let paint = Theme.paint () in
  let track_style = Theme.border_muted () in
  let label_style = Theme.recede () in
  let ok_bar =
    Chart.dot_meter ~width:cells ~value:total_ok ~max_value:total_all
      ~scale:(Chart.Series { paint; series = Masc_tui_theme.Completion })
      ~label:(say "정상" "ok") ~label_style ~track_style ~reset:Ansi.reset ()
  in
  let err_bar =
    Chart.dot_meter ~width:cells ~value:total_bad ~max_value:total_all
      ~scale:(Chart.Declared_limit paint)
      ~label:(say "실패" "err") ~label_style ~track_style ~reset:Ansi.reset ()
  in
  let peak_line =
    Theme.recede ()
    ^ Layout.truncate_end cells
        (Printf.sprintf
           (if ko then "최고 ↑%d ↓%d / 30분" else "peak ↑%d ↓%d / 30m")
           peak_ok peak_bad)
    ^ Ansi.reset
  in
  let active_line =
    Theme.recede ()
    ^ Layout.truncate_end cells
        (Printf.sprintf
           (if ko then "활동 %d/%d · %s" else "act %d/%d · %s")
           active_slots slot_count tail_note)
    ^ Ansi.reset
  in
  [ ok_bar; err_bar; peak_line; active_line ]

let build_baseline_ok_row ~count ~up_arr ~dn_arr ~ok_base_tone ~unknown_at =
  let base_buf = Buffer.create (count * 12) in
  for i = 0 to count - 1 do
    let l, r = up_arr.(i) in
    let dl, dr = dn_arr.(i) in
    if l = 0 && r = 0 && dl = 0 && dr = 0 then
      let mark =
        if unknown_at i then Masc_tui_keeper_mark.grid_unknown_range_mark
        else Masc_tui_keeper_mark.grid_dot_mark
      in
      Buffer.add_string base_buf (Theme.recede () ^ mark ^ Ansi.reset)
    else
      let bl = min 4 l and br = min 4 r in
      let glyph = Braille.braille_pair ~left:bl ~right:br in
      if bl = 0 && br = 0 then Buffer.add_string base_buf glyph
      else Buffer.add_string base_buf (ok_base_tone ^ glyph ^ Ansi.reset)
  done;
  Buffer.contents base_buf

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
    let blank_wave = fit_row (prefix name_cells " " "") in
    [ fit_row row0 ] @ List.init 5 (fun _ -> blank_wave) @ [ legend_row ~ko ~cols ]
  else
    let total_ok, total_bad, active_slots, peak_ok, peak_bad =
      Array.fold_left
        (fun (tok, tbad, act, pok, pbad) (_, ok_sum, bad_sum) ->
          let active = if ok_sum > 0 || bad_sum > 0 then act + 1 else act in
          (tok + ok_sum, tbad + bad_sum, active, max pok ok_sum, max pbad bad_sum))
        (0, 0, 0, 0, 0) slot_agg
    in
    let ok_levels =
      Array.map (fun (_, ok_sum, _) -> scale_wave_level ~levels:12 ~peak:peak_ok ok_sum) slot_agg
    in
    let bad_levels =
      Array.map (fun (_, _, bad_sum) -> scale_wave_level ~levels:12 ~peak:peak_bad bad_sum) slot_agg
    in
    let up_pairs = smooth_wave_pairs ok_levels in
    let down_pairs = smooth_wave_pairs bad_levels in
    let ok_tint = Theme.series_tint Masc_tui_theme.Completion in
    let warm_tint = Theme.warm_tint () in
    let up_r0, up_r1 =
      match Braille.braille_curve_rows ~down:false ~tint:ok_tint ~rows:3 up_pairs with
      | r0 :: r1 :: _ -> (r0, r1)
      | [ r0 ] -> (r0, "")
      | [] -> ("", "")
    in
    let dn_r0, dn_r1, dn_r2 =
      match Braille.braille_curve_rows ~down:true ~tint:warm_tint ~rows:3 down_pairs with
      | r0 :: r1 :: r2 :: _ -> (r0, r1, r2)
      | [ r0; r1 ] -> (r0, r1, "")
      | [ r0 ] -> (r0, "", "")
      | [] -> ("", "", "")
    in
    let up_arr = Array.of_list up_pairs in
    let dn_arr = Array.of_list down_pairs in
    let ok_base_tone = ok_tint 0.0 in
    let up_base =
      build_baseline_ok_row ~count ~up_arr ~dn_arr ~ok_base_tone ~unknown_at:(fun i ->
        let fc, _, _ = slot_agg.(i) in
        match fc with Pulse.Count_unknown -> true | Pulse.Exact _ | Pulse.At_least _ -> false)
    in
    let pfx_fleet = prefix name_cells " " (say "전체" "fleet") in
    let pfx_blank = prefix name_cells " " "" in
    let prefix_w = Layout.display_width (Masc_tui_theme.strip_sgr pfx_fleet) in
    let wave_span = prefix_w + count in
    let box_room = cols - wave_span - 2 in
    let wave_rows =
      if cols >= 100 && box_room >= 26 then
        let box_w = min 36 box_room in
        let edge =
          { Card.name = say "24h 요약" "24h Fleet"
          ; key = None
          ; status = None
          ; count = None
          ; focus = Card.Unfocused
          ; border_accent = Doc.panel_border_accent Masc_tui_theme.Panel_fleet
          ; footer_keys = []
          }
        in
        let tail_note =
          (if ko then "최대실패 " else "peak ") ^ count_text peak_fail
        in
        let box_lines =
          Card.render ~ko ~style:(Doc.card_style ()) ~width:box_w ~height:6
            { Card.edge
            ; body =
                (fun ~cells ->
                  dot_meter_summary_lines ~ko ~cells ~total_ok ~total_bad
                    ~peak_ok ~peak_bad ~active_slots ~slot_count:count ~tail_note)
            }
        in
        let wave_only =
          [ pfx_fleet ^ up_r0
          ; pfx_blank ^ up_r1
          ; pfx_blank ^ up_base
          ; pfx_blank ^ dn_r0
          ; pfx_blank ^ dn_r1
          ; pfx_blank ^ dn_r2
          ]
        in
        List.mapi
          (fun idx wave ->
            let padded = Layout.fit_width wave wave_span in
            let card = Option.value ~default:"" (List.nth_opt box_lines idx) in
            fit_row (padded ^ "  " ^ card))
          wave_only
      else
        let ok_peak_text =
          if peak_ok <= 0 then Masc_tui_theme.Glyph.no_value else string_of_int peak_ok
        in
        let bad_peak_text =
          if peak_bad <= 0 then Masc_tui_theme.Glyph.no_value else string_of_int peak_bad
        in
        let dim_rule s = Theme.recede () ^ " │ " ^ s ^ Ansi.reset in
        [ fit_row (pfx_fleet ^ up_r0 ^ dim_rule ("↑" ^ say "정상 " "ok " ^ ok_peak_text))
        ; fit_row (pfx_blank ^ up_r1 ^ dim_rule "↑24h")
        ; fit_row (pfx_blank ^ up_base ^ dim_rule (Printf.sprintf (if ko then "%d칸" else "%d slots") count))
        ; fit_row (pfx_blank ^ dn_r0 ^ dim_rule ("↓" ^ say "실패 " "fail " ^ bad_peak_text))
        ; fit_row
            (pfx_blank ^ dn_r1 ^ Theme.recede () ^ (if ko then " │ 최대 " else " │ peak ")
             ^ Ansi.reset ^ count_text peak_fail)
        ; fit_row (pfx_blank ^ dn_r2 ^ Theme.recede () ^ " │" ^ Ansi.reset)
        ]
    in
    wave_rows @ [ legend_row ~ko ~cols ]

let selected_cockpit_rows ~ko ~cols ~now ~name ~status runtime =
  if cols < 44 then []
  else
    let fit_row line = Layout.truncate_end (max 0 cols) line ^ Ansi.reset in
    let _, count = dimensions cols in
    let keeper_tallies = tallies ~now ~count runtime in
    let hours = List.map Pulse.half_hour_of_tally keeper_tallies in
    let hdr =
      Doc.section_header ~width:cols ~indent:2 ~subtitle:status
        (Terminal_text.single_line name)
    in
    if Pulse.nothing_read [ hours ] then
      [ hdr
      ; fit_row
          ("  " ^ Theme.recede ()
           ^ Masc_tui_keeper_strip.history_unknown_label ~cells:(min 24 (max 8 (cols - 4))))
      ; ""
      ; ""
      ; ""
      ]
    else
      let tally_arr = Array.of_list keeper_tallies in
      let total_ok, total_bad, active_slots, peak_ok, peak_bad =
        Array.fold_left
          (fun (tok, tbad, act, pok, pbad) -> function
            | Pulse.Slot_tally_measured { Pulse_wire.ok; rested; failed } ->
                let bad = failed + rested in
                let active = if ok > 0 || bad > 0 then act + 1 else act in
                (tok + ok, tbad + bad, active, max pok ok, max pbad bad)
            | Pulse.Slot_tally_unknown -> (tok, tbad, act, pok, pbad))
          (0, 0, 0, 0, 0) tally_arr
      in
      let ok_levels =
        Array.map
          (function
            | Pulse.Slot_tally_measured { Pulse_wire.ok; _ } ->
                scale_wave_level ~levels:8 ~peak:peak_ok ok
            | Pulse.Slot_tally_unknown -> None)
          tally_arr
      in
      let bad_levels =
        Array.map
          (function
            | Pulse.Slot_tally_measured { Pulse_wire.rested; failed; _ } ->
                scale_wave_level ~levels:8 ~peak:peak_bad (failed + rested)
            | Pulse.Slot_tally_unknown -> None)
          tally_arr
      in
      let up_pairs = smooth_wave_pairs ok_levels in
      let down_pairs = smooth_wave_pairs bad_levels in
      let ok_tint = Theme.series_tint Masc_tui_theme.Completion in
      let warm_tint = Theme.warm_tint () in
      let up_r0 =
        match Braille.braille_curve_rows ~down:false ~tint:ok_tint ~rows:2 up_pairs with
        | r0 :: _ -> r0
        | [] -> ""
      in
      let dn_r0, dn_r1 =
        match Braille.braille_curve_rows ~down:true ~tint:warm_tint ~rows:2 down_pairs with
        | r0 :: r1 :: _ -> (r0, r1)
        | [ r0 ] -> (r0, "")
        | [] -> ("", "")
      in
      let up_arr = Array.of_list up_pairs in
      let dn_arr = Array.of_list down_pairs in
      let up_base =
        build_baseline_ok_row ~count ~up_arr ~dn_arr ~ok_base_tone:(ok_tint 0.0)
          ~unknown_at:(fun i ->
            match tally_arr.(i) with
            | Pulse.Slot_tally_unknown -> true
            | Pulse.Slot_tally_measured _ -> false)
      in
      let wave_lines =
        [ "  " ^ up_r0
        ; "  " ^ up_base
        ; "  " ^ dn_r0
        ; "  " ^ dn_r1
        ]
      in
      let wave_w = 2 + count in
      let right_w = cols - wave_w - 3 in
      if right_w < 18 then
        hdr :: List.map fit_row wave_lines
      else
        let right_lines =
          dot_meter_summary_lines ~ko ~cells:right_w ~total_ok ~total_bad
            ~peak_ok ~peak_bad ~active_slots ~slot_count:count
            ~tail_note:(Printf.sprintf "%d/24h" count)
        in
        let joined =
          List.mapi
            (fun idx wave ->
              let padded = Layout.fit_width wave wave_w in
              let sep = Theme.recede () ^ " │ " ^ Ansi.reset in
              let info = Option.value ~default:"" (List.nth_opt right_lines idx) in
              fit_row (padded ^ sep ^ info))
            wave_lines
        in
        hdr :: joined
