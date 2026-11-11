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
end
