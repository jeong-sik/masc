module Redraw = struct
  (* The earliest instant at which text drawn on the frame being built reads
     differently, kept per domain because only the UI domain builds frames. *)
  let earliest = Domain.DLS.new_key (fun () -> None)

  let begin_frame () = Domain.DLS.set earliest None

  let note_change_at at =
    if Float.is_finite at then
      match Domain.DLS.get earliest with
      | Some sooner when sooner <= at -> ()
      | Some _ | None -> Domain.DLS.set earliest (Some at)

  let next_change () = Domain.DLS.get earliest

  let holds ~now ~until =
    let holding = now <= until in
    if holding then note_change_at until;
    holding

  (* The earlier noting is put back whether [measure] returns or raises, so a
     measurement can neither add a change nor drop one noted before it. *)
  let measuring measure =
    let noted = Domain.DLS.get earliest in
    Fun.protect ~finally:(fun () -> Domain.DLS.set earliest noted) measure

  (* Built inside a measurement, so the frame's own noting is put back
     whether [build] returns or raises; what [build] noted is handed back. *)
  let deferred build =
    measuring (fun () ->
        Domain.DLS.set earliest None;
        let built = build () in
        (built, Domain.DLS.get earliest))
end

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

  let detail_text ?(localtime = Unix.localtime) precision ~now at =
    let tm = localtime at in
    match distance ~now:(localtime now) tm with
    | Same_day -> clock precision tm
    | Same_year -> within_year precision tm
    | Other_year -> year_month_day tm ^ " " ^ clock precision tm

  let day_of ?(localtime = Unix.localtime) ~now at =
    distance ~now:(localtime now) (localtime at)

  let clock_within_day = clock

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

  let seconds_per_minute = 60

  let next_minute ~now =
    let local = Unix.localtime now in
    Float.floor now +. Float.of_int (seconds_per_minute - local.Unix.tm_sec)

  let wall_clock ~now =
    let local = Unix.localtime now in
    clock To_minute local ^ " "
    ^ zone_label ~offset_minutes:(offset_minutes ~utc:(Unix.gmtime now) ~local)

  let axis_hour at =
    let local = Unix.localtime at in
    if local.Unix.tm_min = 0 && local.Unix.tm_sec = 0 then Some (clock To_minute local)
    else None

  let day_start at =
    let day = Unix.localtime at in
    match Unix.mktime { day with Unix.tm_hour = 0; tm_min = 0; tm_sec = 0 } with
    | start, _ -> Some start
    | exception Unix.Unix_error _ -> None

  let file_stamp at =
    let tm = Unix.localtime at in
    Printf.sprintf "%04d%02d%02d-%02d%02d" (tm.Unix.tm_year + tm_year_origin)
      (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
end

let date_text ~year ~month ~day = Printf.sprintf "%04d-%02d-%02d" year month day

module Local_day = struct
  type t =
    { year : int
    ; month : int
    ; day : int
    }

  let of_moment at =
    let tm = Unix.localtime at in
    { year = tm.Unix.tm_year + Instant.tm_year_origin
    ; month = tm.Unix.tm_mon + 1
    ; day = tm.Unix.tm_mday
    }

  let text { year; month; day } = date_text ~year ~month ~day
end

module Local_hour = struct
  type t =
    { year : int
    ; month : int
    ; day : int
    ; hour : int
    ; is_dst : bool
    }

  let of_tm (tm : Unix.tm) =
    { year = tm.Unix.tm_year + Instant.tm_year_origin
    ; month = tm.Unix.tm_mon + 1
    ; day = tm.Unix.tm_mday
    ; hour = tm.Unix.tm_hour
    ; is_dst = tm.Unix.tm_isdst
    }

  let equal left right =
    Int.equal left.year right.year
    && Int.equal left.month right.month
    && Int.equal left.day right.day
    && Int.equal left.hour right.hour
    && Bool.equal left.is_dst right.is_dst

  let heading { year; month; day; hour; is_dst } =
    date_text ~year ~month ~day
    ^ Printf.sprintf " \xc2\xb7 %02d:00" hour
    ^ if is_dst then " DST" else ""
end

module Utc_day = struct
  (* Whole days since the epoch: the UTC day is the floor of the moment in
     days, so two moments on one UTC day give the same value. *)
  type t = int

  let seconds_per_day = 86_400.
  let of_moment at = int_of_float (Float.floor (at /. seconds_per_day))
  let breakdown day = Unix.gmtime (float_of_int day *. seconds_per_day)

  let month_day day = Instant.month_day (breakdown day)
  let date day = Instant.year_month_day (breakdown day)
  let day_of_month day = (breakdown day).Unix.tm_mday
  let day_of_month_text day = Printf.sprintf "%02d" (day_of_month day)
end

module Ongoing = struct
  let seconds_per_minute = 60
  let seconds_per_hour = 60 * seconds_per_minute
  let seconds_per_day = 24 * seconds_per_hour

  (* From a hundred days the ladder drops the hours, as the finished ladder
     does, so a reading stays within six cells. *)
  let days_with_hours = 100 * seconds_per_day

  (* [int_of_float] is defined only below 2^62. Far below that, past this
     many seconds (thirty million years), a value is a malformed stamp. *)
  let longest_whole_seconds = 1_000_000_000_000_000

  (* Whole seconds of a span: a span at or below zero, or one that is not a
     number, is no time at all; one past the longest reads as the longest. *)
  let whole_seconds seconds =
    if not (seconds > 0.) then 0
    else if seconds >= Float.of_int longest_whole_seconds then longest_whole_seconds
    else int_of_float seconds

  (* A ladder reads whole seconds, and [step] is the unit it counts in at a
     length: the time between two of its readings there. *)
  type ladder =
    { read : int -> string
    ; step : int -> int
    }

  let two_units =
    { read =
        (fun whole ->
          if whole < seconds_per_minute then Printf.sprintf "%ds" whole
          else if whole < seconds_per_hour then Printf.sprintf "%dm" (whole / seconds_per_minute)
          else if whole < seconds_per_day then
            Printf.sprintf "%dh%02dm" (whole / seconds_per_hour)
              (whole mod seconds_per_hour / seconds_per_minute)
          else if whole < days_with_hours then
            Printf.sprintf "%dd%02dh" (whole / seconds_per_day)
              (whole mod seconds_per_day / seconds_per_hour)
          else Printf.sprintf "%dd" (whole / seconds_per_day))
    ; step =
        (fun whole ->
          if whole < seconds_per_minute then 1
          else if whole < seconds_per_day then seconds_per_minute
          else if whole < days_with_hours then seconds_per_hour
          else seconds_per_day)
    }

  let one_unit =
    { read =
        (fun whole ->
          if whole < seconds_per_minute then Printf.sprintf "%ds" whole
          else if whole < seconds_per_hour then Printf.sprintf "%dm" (whole / seconds_per_minute)
          else if whole < seconds_per_day then Printf.sprintf "%dh" (whole / seconds_per_hour)
          else Printf.sprintf "%dd" (whole / seconds_per_day))
    ; step =
        (fun whole ->
          if whole < seconds_per_minute then 1
          else if whole < seconds_per_hour then seconds_per_minute
          else if whole < seconds_per_day then seconds_per_hour
          else seconds_per_day)
    }

  let text_on ladder seconds = ladder.read (whole_seconds seconds)

  let reading_floor_on ladder seconds =
    let whole = whole_seconds seconds in
    let step = ladder.step whole in
    Float.of_int (whole / step * step)

  let next_change_on ladder seconds =
    let whole = whole_seconds seconds in
    if whole >= longest_whole_seconds then None
    else
      let step = ladder.step whole in
      Some (Float.of_int ((whole / step + 1) * step))

  let since_on ladder ~now at =
    let seconds = now -. at in
    if Float.is_finite seconds then
      Option.iter
        (fun next -> Redraw.note_change_at (at +. next))
        (next_change_on ladder (Float.max 0. seconds));
    text_on ladder seconds

  let until_on ladder ~now at =
    let seconds = at -. now in
    (if Float.is_finite seconds && seconds > 0. then begin
       let floor = reading_floor_on ladder seconds in
       (* Below its first second the countdown already reads [0s], as every
          moment after it does. *)
       if floor > 0. then Redraw.note_change_at (at -. floor);
       (* A screen words a moment that has come differently from one still
          coming ("in 5m" against "late 1m"), so its arrival is a change too. *)
       Redraw.note_change_at at
     end);
    text_on ladder seconds

  let text = text_on two_units
  let next_change = next_change_on two_units
  let reading_floor = reading_floor_on two_units
  let since = since_on two_units
  let age ~now seconds = since ~now (now -. seconds)
  let until = until_on two_units

  module Narrow = struct
    let text = text_on one_unit
    let next_change = next_change_on one_unit
    let reading_floor = reading_floor_on one_unit
    let since = since_on one_unit
    let until = until_on one_unit
  end
end

module Interval = struct
  let seconds_per_minute = 60
  let seconds_per_hour = 60 * seconds_per_minute
  let seconds_per_day = 24 * seconds_per_hour

  let text seconds =
    let lossy () = Ongoing.text (Float.of_int seconds) in
    if seconds <= 0 then "0s"
    else if seconds < seconds_per_minute then Printf.sprintf "%ds" seconds
    else if seconds mod seconds_per_day = 0 then
      Printf.sprintf "%dd" (seconds / seconds_per_day)
    else if seconds >= seconds_per_day then
      if seconds mod seconds_per_hour = 0 then
        Printf.sprintf "%dd%02dh" (seconds / seconds_per_day)
          (seconds mod seconds_per_day / seconds_per_hour)
      else lossy ()
    else if seconds mod seconds_per_hour = 0 then
      Printf.sprintf "%dh" (seconds / seconds_per_hour)
    else if seconds >= seconds_per_hour then
      if seconds mod seconds_per_minute = 0 then
        Printf.sprintf "%dh%02dm" (seconds / seconds_per_hour)
          (seconds mod seconds_per_hour / seconds_per_minute)
      else lossy ()
    else if seconds mod seconds_per_minute = 0 then
      Printf.sprintf "%dm" (seconds / seconds_per_minute)
    else
      Printf.sprintf "%dm%02ds" (seconds / seconds_per_minute) (seconds mod seconds_per_minute)

  (* [int_of_float] is defined only below 2^62; far below that a setting is a
     malformed value, not a span anyone set. *)
  let largest_whole_setting = 1e15

  let of_seconds seconds =
    let whole = Float.ceil seconds in
    if Float.is_finite whole && Float.abs whole < largest_whole_setting then
      text (int_of_float whole)
    else Ongoing.text whole
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

module Unknown = struct
  type t =
    | Unread
    | Read_failed
    | Unreported

  let glyph = function
    | Unread -> "\xe2\x97\x8c"
    | Read_failed -> Mark.glyph Mark.Failed
    | Unreported -> "?"
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
    | File
    | Task
    | Open_task
    | Claim
    | Conflict

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
    | File -> "file", "files"
    | Task -> "task", "tasks"
    | Open_task -> "open task", "open tasks"
    | Claim -> "claim", "claims"
    | Conflict -> "conflict", "conflicts"

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
    | File -> "파일 " ^ figure ^ "개"
    | Task -> "작업 " ^ figure ^ "개"
    | Open_task -> "열린 작업 " ^ figure ^ "개"
    | Claim -> "공유 주장 " ^ figure ^ "건"
    | Conflict -> "충돌 " ^ figure ^ "건"

  let written ~ko noun count figure =
    if ko then korean noun figure
    else
      let one, many = english noun in
      figure ^ " " ^ if count = 1 then one else many

  let reading ~ko noun count = written ~ko noun count (grouped count)

  let lower_bound count = "≥" ^ grouped count

  let at_least ~ko noun count = written ~ko noun count (lower_bound count)

  (* The word ahead of the server's total when a list is read in part. *)
  let whole ~ko = if ko then "전체" else "of"

  (* Two facts of the same rank (RFC section 6.5). *)
  let joiner = " \xc2\xb7 "

  let partial ~ko ~loaded ~total =
    grouped loaded ^ joiner ^ whole ~ko ^ " " ^ grouped total

  let more ~ko count =
    if ko then "외 " ^ grouped count else grouped count ^ " more"
end

module Hash = struct
  let shown_length = 12

  (* [String.sub] raises on a value shorter than the cut, so a short value is
     returned as it is. *)
  let short value =
    if String.length value <= shown_length then value
    else String.sub value 0 shown_length
end

module Position = struct
  type t =
    | Row of { at : int; total : int }
    | Window of { first : int; last : int; total : int }
    | Partial of { at : int; loaded : int; total : int }

  (* The selected index as a row counted from one, held inside the list: a
     cursor left past the end by a list that shrank names the last row. *)
  let selected_row ~selected ~total =
    match selected with
    | None -> 0
    | Some _ when total <= 0 -> 0
    | Some index -> Int.max 0 (Int.min index (total - 1)) + 1

  let row ~selected ~total =
    let total = Int.max 0 total in
    Row { at = selected_row ~selected ~total; total }

  let partial ~selected ~loaded ~total =
    let loaded = Int.max 0 loaded in
    Partial { at = selected_row ~selected ~total:loaded; loaded; total = Int.max loaded total }

  let window ~first ~shown ~total =
    if total <= shown then None
    else if shown <= 0 then Some (Window { first = 0; last = 0; total })
    else
      let first = Int.max 0 (Int.min first (total - 1)) in
      Some (Window { first = first + 1; last = Int.min total (first + shown); total })
end
