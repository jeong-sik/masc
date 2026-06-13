(** ISO-8601 timestamp helpers kept small and local to [masc_gate] so the
    library does not depend on [lib/server/server_utils.ml] (HTTP routing
    types) nor on [lib/types/] (Masc_domain.parse_iso8601_opt drags the whole
    masc_types surface in for a 17-line helper).

    When Gate moves out of the MASC monolith (Track B4), the remaining
    external deps reduce to yojson/eio/unix/fs_compat — this file is part
    of that cleanup. *)

let iso8601_of_unix ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

(** Parse UTC ISO8601 timestamps to Unix float. Accepts the compact [Z] form
    emitted by OCaml code and Python's [datetime.isoformat] UTC form with
    fractional seconds and [+00:00]. *)
let has_suffix s suffix =
  let s_len = String.length s in
  let suffix_len = String.length suffix in
  s_len >= suffix_len
  && String.equal
       (String.sub s (s_len - suffix_len) suffix_len)
       suffix

let drop_suffix s suffix =
  String.sub s 0 (String.length s - String.length suffix)

let strip_fractional_seconds s =
  match String.index_opt s '.' with
  | None -> s
  | Some dot ->
      let len = String.length s in
      let rec find_suffix i =
        if i >= len then len
        else
          match s.[i] with
          | 'Z' | '+' | '-' -> i
          | _ -> find_suffix (i + 1)
      in
      let suffix_start = find_suffix (dot + 1) in
      String.sub s 0 dot ^ String.sub s suffix_start (len - suffix_start)

let normalize_utc_iso8601 s =
  let s = s |> String.trim |> strip_fractional_seconds in
  if has_suffix s "Z" then Some s
  else if has_suffix s "+00:00" then Some (drop_suffix s "+00:00" ^ "Z")
  else if has_suffix s "-00:00" then Some (drop_suffix s "-00:00" ^ "Z")
  else None

let parse_iso8601_opt s =
  match normalize_utc_iso8601 s with
  | None -> None
  | Some s -> (
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
  with Scanf.Scan_failure _ | Failure _ | End_of_file -> None)
