module Instant = struct
  type distance =
    | Same_day
    | Same_year
    | Other_year

  let distance ~(now : Unix.tm) (at : Unix.tm) =
    if at.Unix.tm_year <> now.Unix.tm_year then Other_year
    else if at.Unix.tm_yday <> now.Unix.tm_yday then Same_year
    else Same_day

  type precision =
    | To_minute
    | To_second

  (* [Unix.tm] counts years from 1900 and months from zero. *)
  let tm_year_origin = 1900

  let clock precision (tm : Unix.tm) =
    match precision with
    | To_minute -> Printf.sprintf "%02d:%02d" tm.Unix.tm_hour tm.Unix.tm_min
    | To_second ->
        Printf.sprintf "%02d:%02d:%02d" tm.Unix.tm_hour tm.Unix.tm_min
          tm.Unix.tm_sec

  let month_day (tm : Unix.tm) =
    Printf.sprintf "%02d-%02d" (tm.Unix.tm_mon + 1) tm.Unix.tm_mday

  let year_month_day (tm : Unix.tm) =
    Printf.sprintf "%04d-%s" (tm.Unix.tm_year + tm_year_origin) (month_day tm)

  let within_year precision tm = month_day tm ^ " " ^ clock precision tm

  let cell_text precision ~now at =
    let tm = Unix.localtime at in
    match distance ~now:(Unix.localtime now) tm with
    | Same_day -> clock precision tm
    | Same_year -> within_year precision tm
    | Other_year -> year_month_day tm

  (* The widest column form is the one inside this year: every field in it is
     zero-padded, so any moment measures the same. *)
  let cell_width precision =
    String.length (within_year precision (Unix.gmtime 0.0))

  let detail_text precision ~now at =
    let tm = Unix.localtime at in
    match distance ~now:(Unix.localtime now) tm with
    | Same_day -> clock precision tm
    | Same_year -> within_year precision tm
    | Other_year -> year_month_day tm ^ " " ^ clock precision tm

  let minutes_per_hour = 60
  let minutes_per_day = 24 * minutes_per_hour

  (* The two breakdowns are of one moment, so they are at most a day apart,
     and which side of midnight each fell on is the only thing the calendar
     fields add to the clock fields. *)
  let offset_minutes ~(utc : Unix.tm) ~(local : Unix.tm) =
    let day_delta =
      if local.Unix.tm_year <> utc.Unix.tm_year then
        compare local.Unix.tm_year utc.Unix.tm_year
      else compare local.Unix.tm_yday utc.Unix.tm_yday
    in
    let of_day (tm : Unix.tm) =
      (tm.Unix.tm_hour * minutes_per_hour) + tm.Unix.tm_min
    in
    (day_delta * minutes_per_day) + of_day local - of_day utc

  let zone_label ~offset_minutes =
    if offset_minutes = 0 then "UTC"
    else
      let sign = if offset_minutes < 0 then '-' else '+' in
      let distance = abs offset_minutes in
      let hours = distance / minutes_per_hour in
      match distance mod minutes_per_hour with
      | 0 -> Printf.sprintf "UTC%c%d" sign hours
      | minutes -> Printf.sprintf "UTC%c%d:%02d" sign hours minutes

  let wall_clock ~now =
    let local = Unix.localtime now in
    clock To_minute local ^ " "
    ^ zone_label ~offset_minutes:(offset_minutes ~utc:(Unix.gmtime now) ~local)
end

module Mark = struct
  type t =
    | Settled
    | Under_way
    | Waiting
    | Paused
    | Caution
    | Failed
    | Yours

  let glyph = function
    | Settled -> "\xe2\x97\x8f"
    | Under_way -> "\xe2\x97\x90"
    | Waiting -> "\xe2\x97\x8b"
    | Paused -> "\xe2\x80\x96"
    | Caution -> "\xe2\x96\xb2"
    | Failed -> "\xe2\x9c\x95"
    | Yours -> "\xe2\x97\x86"
end

module Count = struct
  (* Digits between two separators. *)
  let group_size = 3

  let grouped value =
    let digits = string_of_int value in
    (* A minus sign is not a digit: counting it put the first separator one
       place early, and [-123456] read [-,123,456]. *)
    let sign = if value < 0 then 1 else 0 in
    let length = String.length digits in
    let text = Buffer.create (length + (length / group_size)) in
    String.iteri
      (fun index digit ->
        if index > sign && (length - index) mod group_size = 0 then
          Buffer.add_char text ',';
        Buffer.add_char text digit)
      digits;
    Buffer.contents text

  type noun =
    | Keeper
    | Run
    | Call
    | Post
    | Entry
    | Row
    | Event
    | Image

  (* Singular, plural. *)
  let english = function
    | Keeper -> "keeper", "keepers"
    | Run -> "run", "runs"
    | Call -> "call", "calls"
    | Post -> "post", "posts"
    | Entry -> "entry", "entries"
    | Row -> "row", "rows"
    | Event -> "event", "events"
    | Image -> "image", "images"

  (* The thing, then the figure with its counter. A row is counted by the
     word that names it. *)
  let korean noun figure =
    match noun with
    | Keeper -> "키퍼 " ^ figure ^ "명"
    | Run -> "실행 " ^ figure ^ "건"
    | Call -> "호출 " ^ figure ^ "건"
    | Post -> "글 " ^ figure ^ "개"
    | Entry -> "기록 " ^ figure ^ "건"
    | Row -> figure ^ "줄"
    | Event -> "이벤트 " ^ figure ^ "개"
    | Image -> "그림 " ^ figure ^ "장"

  let reading ~ko noun count =
    let figure = grouped count in
    if ko then korean noun figure
    else
      let one, many = english noun in
      figure ^ " " ^ if count = 1 then one else many
end

module Position = struct
  type t =
    | Row of { at : int; total : int }
    | Partial of { at : int; loaded : int; total : int }

  (* The mark for a value that is absent (RFC section 6.4). *)
  let nothing_selected = "\xe2\x80\x94"

  let text ~whole = function
    | Row { at = 0; total } -> nothing_selected ^ "/" ^ Count.grouped total
    | Row { at; total } -> Count.grouped at ^ "/" ^ Count.grouped total
    | Partial { at; loaded; total } ->
        Count.grouped at ^ "/" ^ Count.grouped loaded ^ " \xc2\xb7 " ^ whole
        ^ " " ^ Count.grouped total
end
