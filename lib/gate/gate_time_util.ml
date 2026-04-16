(** ISO-8601 timestamp helpers kept small and local to [masc_gate] so the
    library does not depend on [lib/server/server_utils.ml] (HTTP routing
    types) nor on [lib/types/] (Types.parse_iso8601_opt drags the whole
    masc_types surface in for a 17-line helper).

    When Gate moves out of the MASC monolith (Track B4), the remaining
    external deps reduce to yojson/eio/unix/fs_compat — this file is part
    of that cleanup. *)

let iso8601_of_unix ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

(** Parse ISO8601 "YYYY-MM-DDTHH:MM:SSZ" to Unix float (UTC). Duplicated
    locally from [Types.parse_iso8601_opt] to sever the dependency on
    [masc_types]. Behavior byte-identical to the original. *)
let parse_iso8601_opt s =
  try
    Scanf.sscanf s "%04d-%02d-%02dT%02d:%02d:%02dZ"
      (fun year mon day hour min sec ->
        let tm = {
          Unix.tm_sec = sec; tm_min = min; tm_hour = hour;
          tm_mday = day; tm_mon = mon - 1; tm_year = year - 1900;
          tm_wday = 0; tm_yday = 0; tm_isdst = false;
        } in
        let local_epoch, _ = Unix.mktime tm in
        let utc_of_local = Unix.gmtime local_epoch in
        let utc_as_local, _ = Unix.mktime utc_of_local in
        let tz_offset = local_epoch -. utc_as_local in
        Some (local_epoch +. tz_offset))
  with Scanf.Scan_failure _ | Failure _ | End_of_file -> None
