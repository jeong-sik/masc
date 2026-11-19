module Domain = Schedule_domain

let seconds_per_minute = 60
let seconds_per_hour = 60 * seconds_per_minute
let seconds_per_day = 24 * seconds_per_hour

(* A daily wake is a wall-clock time at a fixed offset. The operator reads
   it on their own clock, so it is placed on the UTC day of [now] and broken
   down in the local zone; the day only matters where the local zone moves
   its offset. *)
let local_clock ~now ~hour ~minute ~second ~offset =
  let utc_day_start = Float.of_int seconds_per_day *. Float.floor (now /. Float.of_int seconds_per_day) in
  let utc_seconds = (hour * seconds_per_hour) + (minute * seconds_per_minute) + second - offset in
  let tm = Unix.localtime (utc_day_start +. Float.of_int utc_seconds) in
  if tm.Unix.tm_sec = 0 then Printf.sprintf "%02d:%02d" tm.tm_hour tm.tm_min
  else Printf.sprintf "%02d:%02d:%02d" tm.tm_hour tm.tm_min tm.tm_sec

let text ~ko ~now ~summary = function
  | Ok Domain.One_shot -> if ko then "한 번" else "once"
  | Ok (Domain.Interval { interval_sec }) ->
      let span = Masc_tui_value.Interval.text interval_sec in
      if ko then "매 " ^ span else "every " ^ span
  | Ok (Domain.Daily { hour; minute; second; timezone }) -> (
      match Domain.timezone_offset_seconds timezone with
      | Some offset ->
          let clock = local_clock ~now ~hour ~minute ~second ~offset in
          if ko then "매일 " ^ clock else "daily " ^ clock
      | None -> summary)
  | Ok (Domain.Cron _ as recurrence) -> Domain.recurrence_summary recurrence
  | Error _ -> summary
