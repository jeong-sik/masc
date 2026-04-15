(** ISO-8601 timestamp formatter for Gate audit/status records.

    Kept small and local to [masc_gate] so the library does not depend on
    [lib/server/server_utils.ml] (which pulls in HTTP routing types). *)

let iso8601_of_unix ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec
