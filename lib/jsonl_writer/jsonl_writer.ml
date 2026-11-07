(* One gmtime call behind both the path the writer picks and the key readers
   filter with. Keeping them on separate calls is what lets one side drift to
   local time while the other stays UTC — the reader then looks in a different
   file than the writer wrote, for the hours where the two calendars disagree. *)
let utc_calendar_day ~ts =
  let tm = Unix.gmtime ts in
  tm.Unix.tm_year + 1900, tm.Unix.tm_mon + 1, tm.Unix.tm_mday
;;

let day_key ~ts =
  let year, month, day = utc_calendar_day ~ts in
  if year >= 0 && year <= 9999 then begin
    let buf = Bytes.create 10 in
    let yq = year / 100 in
    let yr = year - (yq * 100) in
    Bytes.unsafe_set buf 0 (Char.unsafe_chr (48 + (yq / 10)));
    Bytes.unsafe_set buf 1 (Char.unsafe_chr (48 + (yq mod 10)));
    Bytes.unsafe_set buf 2 (Char.unsafe_chr (48 + (yr / 10)));
    Bytes.unsafe_set buf 3 (Char.unsafe_chr (48 + (yr mod 10)));
    Bytes.unsafe_set buf 4 '-';
    Bytes.unsafe_set buf 5 (Char.unsafe_chr (48 + (month / 10)));
    Bytes.unsafe_set buf 6 (Char.unsafe_chr (48 + (month mod 10)));
    Bytes.unsafe_set buf 7 '-';
    Bytes.unsafe_set buf 8 (Char.unsafe_chr (48 + (day / 10)));
    Bytes.unsafe_set buf 9 (Char.unsafe_chr (48 + (day mod 10)));
    Bytes.unsafe_to_string buf
  end else
    Printf.sprintf "%04d-%02d-%02d" year month day
;;

let append_jsonl ~path json =
  Fs_compat.append_jsonl path json
