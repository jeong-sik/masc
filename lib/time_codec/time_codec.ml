type parse_error = Invalid_rfc3339

(* Kept on [Unix.gmtime] rather than [Ptime.to_rfc3339] so that collapsing
   the eight copies changes no output. Ptime cannot represent the whole
   float range, so a Ptime-backed writer would have to return an option and
   every caller would have to answer for it — that is #27131, not this. *)
(* Sub-second callers used to hand-roll this because the module only offered
   whole seconds. Keeping it here means the two spellings cannot drift in the
   part they share. *)
let rfc3339_of_unix_ms seconds =
  let tm = Unix.gmtime seconds in
  let millis = int_of_float ((seconds -. Float.floor seconds) *. 1000.0) in
  Printf.sprintf
    "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec
    millis
;;

let rfc3339_of_unix seconds =
  let tm = Unix.gmtime seconds in
  Printf.sprintf
    "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec
;;

let parse_ptime ?(strict = true) value =
  match Ptime.of_rfc3339 ~strict value with
  | Ok (timestamp, _, _) -> Ok timestamp
  | Error _ -> Error Invalid_rfc3339
;;

let parse_rfc3339 ?(strict = true) value =
  Result.map Ptime.to_float_s (parse_ptime ~strict value)
;;

let parse_rfc3339_whole_seconds ?(strict = true) value =
  Result.map
    (fun timestamp -> Ptime.to_float_s (Ptime.truncate ~frac_s:0 timestamp))
    (parse_ptime ~strict value)
;;

let parse_rfc3339_opt ?(strict = true) value =
  match parse_rfc3339 ~strict value with
  | Ok timestamp -> Some timestamp
  | Error Invalid_rfc3339 -> None
;;
