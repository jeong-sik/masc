type dated_path =
  { base_dir : string
  ; month_dir : string
  ; day_file : string
  ; path : string
  }



(* One gmtime call behind both the path the writer picks and the key readers
   filter with. Keeping them on separate calls is what lets one side drift to
   local time while the other stays UTC — the reader then looks in a different
   file than the writer wrote, for the hours where the two calendars disagree. *)
let utc_calendar_day ts =
  let tm = Unix.gmtime ts in
  tm.Unix.tm_year + 1900, tm.Unix.tm_mon + 1, tm.Unix.tm_mday
;;

let dated_path ~base_dir ~ts =
  let year, month, day = utc_calendar_day ts in
  let month_dir = Printf.sprintf "%04d-%02d" year month in
  let day_file = Printf.sprintf "%02d.jsonl" day in
  let path = Filename.concat (Filename.concat base_dir month_dir) day_file in
  { base_dir; month_dir; day_file; path }
;;

let day_key ~ts =
  let year, month, day = utc_calendar_day ts in
  Printf.sprintf "%04d-%02d-%02d" year month day
;;

let dated_path_now ~base_dir =
  (* NDT-OK: this helper is the runtime write boundary for date-split JSONL;
     deterministic callers use [dated_path ~ts] with an explicit timestamp. *)
  dated_path ~base_dir ~ts:(Unix.gettimeofday ())

let append_jsonl ~path json =
  Fs_compat.append_jsonl path json

let append_dated_jsonl ~base_dir ~ts json =
  let dated = dated_path ~base_dir ~ts in
  append_jsonl ~path:dated.path json;
  dated
