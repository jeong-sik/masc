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
  Printf.sprintf "%04d-%02d-%02d" year month day
;;

let append_jsonl ~path json =
  Fs_compat.append_jsonl path json
