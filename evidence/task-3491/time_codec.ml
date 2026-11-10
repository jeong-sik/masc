type parse_error = Invalid_rfc3339

(* Kept on [Unix.gmtime] rather than [Ptime.to_rfc3339] so that collapsing
   the eight copies changes no output. Ptime cannot represent the whole
   float range, so a Ptime-backed writer would have to return an option and
   every caller would have to answer for it — that is #27131, not this. *)
(* Sub-second callers used to hand-roll this because the module only offered
   whole seconds. Keeping it here means the two spellings cannot drift in the
   part they share. *)
let[@inline always] write_2d bytes off v =
  let q = v / 10 in
  let r = v - (q * 10) in
  Bytes.unsafe_set bytes off (Char.unsafe_chr (48 + q));
  Bytes.unsafe_set bytes (off + 1) (Char.unsafe_chr (48 + r))
;;

let[@inline always] write_4d bytes off v =
  let q = v / 100 in
  let r = v - (q * 100) in
  write_2d bytes off q;
  write_2d bytes (off + 2) r
;;

let[@inline always] write_3d bytes off v =
  let q = v / 100 in
  let rem = v - (q * 100) in
  let q2 = rem / 10 in
  let r2 = rem - (q2 * 10) in
  Bytes.unsafe_set bytes off (Char.unsafe_chr (48 + q));
  Bytes.unsafe_set bytes (off + 1) (Char.unsafe_chr (48 + q2));
  Bytes.unsafe_set bytes (off + 2) (Char.unsafe_chr (48 + r2))
;;

let rfc3339_of_unix_ms seconds =
  let tm = Unix.gmtime seconds in
  let year = tm.Unix.tm_year + 1900 in
  let millis = int_of_float ((seconds -. Float.floor seconds) *. 1000.0) in
  let millis = if millis < 0 then 0 else if millis > 999 then 999 else millis in
  if year >= 0 && year <= 9999 then begin
    let buf = Bytes.create 24 in
    write_4d buf 0 year;
    Bytes.unsafe_set buf 4 '-';
    write_2d buf 5 (tm.Unix.tm_mon + 1);
    Bytes.unsafe_set buf 7 '-';
    write_2d buf 8 tm.Unix.tm_mday;
    Bytes.unsafe_set buf 10 'T';
    write_2d buf 11 tm.Unix.tm_hour;
    Bytes.unsafe_set buf 13 ':';
    write_2d buf 14 tm.Unix.tm_min;
    Bytes.unsafe_set buf 16 ':';
    write_2d buf 17 tm.Unix.tm_sec;
    Bytes.unsafe_set buf 19 '.';
    write_3d buf 20 millis;
    Bytes.unsafe_set buf 23 'Z';
    Bytes.unsafe_to_string buf
  end else
    Printf.sprintf
      "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ"
      year
      (tm.Unix.tm_mon + 1)
      tm.Unix.tm_mday
      tm.Unix.tm_hour
      tm.Unix.tm_min
      tm.Unix.tm_sec
      millis
;;

let rfc3339_of_unix seconds =
  let tm = Unix.gmtime seconds in
  let year = tm.Unix.tm_year + 1900 in
  if year >= 0 && year <= 9999 then begin
    let buf = Bytes.create 20 in
    write_4d buf 0 year;
    Bytes.unsafe_set buf 4 '-';
    write_2d buf 5 (tm.Unix.tm_mon + 1);
    Bytes.unsafe_set buf 7 '-';
    write_2d buf 8 tm.Unix.tm_mday;
    Bytes.unsafe_set buf 10 'T';
    write_2d buf 11 tm.Unix.tm_hour;
    Bytes.unsafe_set buf 13 ':';
    write_2d buf 14 tm.Unix.tm_min;
    Bytes.unsafe_set buf 16 ':';
    write_2d buf 17 tm.Unix.tm_sec;
    Bytes.unsafe_set buf 19 'Z';
    Bytes.unsafe_to_string buf
  end else
    Printf.sprintf
      "%04d-%02d-%02dT%02d:%02d:%02dZ"
      year
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
