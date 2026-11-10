module Pulse = Masc.Keeper_turn_pulse
module Mark = Masc_tui_keeper_mark

type t =
  { name_cells : int
  ; side_cells : int
  ; mem_cells : int
  }

let gutter_cells = 4
let now_cells = 12
let due_cells = 5

(* The pieces between the columns: one space, " ┃ " on each side of the now
   cell, and the strip's now slot. *)
let gap_cells = 1
let line_cells = 3
let now_slot_cells = 1

(* The mock's widths: the right column needs a list of 96 cells, the name
   keeps 22 cells beside it (18 without it), and the pulse and the strip take
   at most 24 half hours each. *)
let mem_min_cols = 96
let mem_field_cells = 7
let name_min_wide = 22
let name_min_narrow = 18
let side_max = 24

let fixed_cells =
  gutter_cells + gap_cells + line_cells + now_cells + line_cells + now_slot_cells + gap_cells
  + due_cells

(* With no pulse and no strip, their spaces and the now slot go too. *)
let fixed_cells_without_side = gutter_cells + line_cells + now_cells + line_cells + due_cells

let layout ~cols =
  let wide = cols >= mem_min_cols in
  let mem_cells = if wide then mem_field_cells else 0 in
  let extra = if wide then gap_cells + mem_field_cells else 0 in
  let name_min = if wide then name_min_wide else name_min_narrow in
  let side = min side_max ((cols - fixed_cells - extra - name_min) / 2) in
  if side > 0 then { name_cells = cols - fixed_cells - extra - (2 * side); side_cells = side; mem_cells }
  else { name_cells = max 0 (cols - fixed_cells_without_side - extra); side_cells = 0; mem_cells }
;;

let strip_cells t = if t.side_cells > 0 then now_slot_cells + t.side_cells else 0

let minute_seconds = int_of_float Masc_time_constants.minute
let slot_minutes = Pulse.slot_seconds / minute_seconds
let minutes_per_hour = Masc_time_constants.hour_int / minute_seconds

let window_of_minutes minutes =
  let hours = minutes / minutes_per_hour and rest = minutes mod minutes_per_hour in
  if hours = 0 then Printf.sprintf "%dm" rest
  else if rest = 0 then Printf.sprintf "%dh" hours
  else Printf.sprintf "%dh%02dm" hours rest
;;

let window_label ~slots = window_of_minutes (slots * slot_minutes)

let slot_label = window_label ~slots:1

type verdict = Masc_tui_keeper_verdict.t =
  | Failing of { resting : bool }
  | Paused
  | Recovered
  | Sound
  | Other

let recovery_slots = Masc_tui_keeper_verdict.recovery_slots
let verdict = Masc_tui_keeper_verdict.of_runtime

let marks_recovery = function
  | Masc_tui_keeper_list_model.By_cause -> true
  | Masc_tui_keeper_list_model.Plain | Masc_tui_keeper_list_model.By_state
  | Masc_tui_keeper_list_model.By_time | Masc_tui_keeper_list_model.By_memory
  | Masc_tui_keeper_list_model.By_age | Masc_tui_keeper_list_model.By_runtime
  | Masc_tui_keeper_list_model.Day_wall -> false
;;

let mark view = function
  | Failing _ -> Mark.grid_failing_mark
  | Paused -> Mark.grid_paused_mark
  | Recovered when marks_recovery view -> Mark.grid_recovered_mark
  | Recovered | Sound | Other -> Mark.grid_ok_mark
;;

let levels =
  [| "\xe2\x96\x81"; "\xe2\x96\x82"; "\xe2\x96\x83"; "\xe2\x96\x84"
   ; "\xe2\x96\x85"; "\xe2\x96\x86"; "\xe2\x96\x87"; "\xe2\x96\x88" |]
(* ▁▂▃▄▅▆▇█ *)

let level_glyph ~peak value =
  if value <= 0 then levels.(0)
  else
    let steps = Array.length levels in
    let ratio = float_of_int value /. float_of_int (max peak value) in
    let index = int_of_float (Float.ceil (ratio *. float_of_int steps)) - 1 in
    levels.(max 0 (min (steps - 1) index))
;;

let day_seconds = Masc_time_constants.day
let half_day_seconds = day_seconds /. 2.
let past_half_day_text = ">" ^ window_label ~slots:(Masc_time_constants.day_int / 2 / Pulse.slot_seconds)

let clock_text ~localtime at =
  let tm = localtime at in
  Printf.sprintf "%02d:%02d" tm.Unix.tm_hour tm.Unix.tm_min
;;

let due_text ~now ~localtime = function
  | Masc_tui_keeper_next_run.No_schedule -> ""
  | Masc_tui_keeper_next_run.Scheduled_at at ->
      if at -. now < day_seconds then clock_text ~localtime at
      else Masc_tui_message_layout.span_text (at -. now)
  | Masc_tui_keeper_next_run.Late_since _ -> Mark.grid_late_word
  | Masc_tui_keeper_next_run.Held_current _ -> Mark.grid_held_word
  | Masc_tui_keeper_next_run.Held_as_of _ -> Mark.grid_held_word ^ Mark.unknown_mark
  | Masc_tui_keeper_next_run.Not_before at ->
      if at -. now > half_day_seconds then past_half_day_text else Mark.unknown_mark
  | Masc_tui_keeper_next_run.Unknown -> Mark.unknown_mark
;;

type strip_cell =
  | Strip_wake
  | Strip_empty
  | Strip_unknown

let strip_cell = function
  | Masc_tui_keeper_next_run.Wakes count -> if count > 0 then Strip_wake else Strip_empty
  (* A slot holding both a known count and an unknown remainder draws as the
     unknown mark: the certain fact is that this slot is not fully known. *)
  | Masc_tui_keeper_next_run.Wakes_with_unknown _ ->
      Masc_tui_keeper_grid.Strip_unknown
  | Masc_tui_keeper_next_run.Wakes_unknown -> Strip_unknown
;;

let strip_mark = function
  | Strip_wake -> Mark.grid_wake_mark
  | Strip_empty -> " "
  | Strip_unknown -> Mark.grid_unknown_range_mark
;;

let lag_fill ~cells ~peak lag =
  if lag <= 0 || cells <= 0 then 0
  else
    let ratio = float_of_int lag /. float_of_int (max peak lag) in
    max 1 (int_of_float (Float.round (ratio *. float_of_int cells)))
;;

(* The mock's [dur] ladder, which keeps a span within the due column: seconds
   under a minute and a half, minutes under a hundred, hours and minutes under
   ten hours, hours under two days, then days. *)
let seconds_ceiling = 90
let minutes_ceiling = 100
let hours_with_minutes_ceiling = 10
let hours_ceiling = 48
let hours_per_day = Masc_time_constants.day_int / Masc_time_constants.hour_int

let short_span seconds =
  let seconds = max 0 (int_of_float (Float.round seconds)) in
  let minutes = int_of_float (Float.round (float_of_int seconds /. float_of_int minute_seconds)) in
  let hours = minutes / minutes_per_hour and rest = minutes mod minutes_per_hour in
  if seconds < seconds_ceiling then Printf.sprintf "%ds" seconds
  else if minutes < minutes_ceiling then Printf.sprintf "%dm" minutes
  else if hours < hours_with_minutes_ceiling then
    if rest = 0 then Printf.sprintf "%dh" hours else Printf.sprintf "%dh%02dm" hours rest
  else if hours < hours_ceiling then Printf.sprintf "%dh" hours
  else
    Printf.sprintf "%dd"
      (int_of_float (Float.round (float_of_int hours /. float_of_int hours_per_day)))
;;

let dated_clock_text ~now ~localtime at =
  if now -. at < half_day_seconds then clock_text ~localtime at
  else
    let tm = localtime at in
    Printf.sprintf "%02d-%02d %s" (tm.Unix.tm_mon + 1) tm.Unix.tm_mday (clock_text ~localtime at)
;;

let chain_attempts = 4
