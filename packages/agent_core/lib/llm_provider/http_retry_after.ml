(* Parsing of the [Retry-After] response header (RFC 9110 S10.2.3).
   The two grammars the spec allows are a delay in seconds and an
   IMF-fixdate. Nothing here reads the clock: the caller passes [now]. *)

let all_digits s = String.length s > 0 && String.for_all (fun c -> c >= '0' && c <= '9') s
let digits_of_len n s = String.length s = n && all_digits s

let month_of_abbrev = function
  | "Jan" -> Some 1
  | "Feb" -> Some 2
  | "Mar" -> Some 3
  | "Apr" -> Some 4
  | "May" -> Some 5
  | "Jun" -> Some 6
  | "Jul" -> Some 7
  | "Aug" -> Some 8
  | "Sep" -> Some 9
  | "Oct" -> Some 10
  | "Nov" -> Some 11
  | "Dec" -> Some 12
  | _ -> None
;;

(* Days since the Unix epoch (1970-01-01) for a proleptic-Gregorian civil
   date. Howard Hinnant's [days_from_civil] algorithm ("chrono-Compatible
   Low-Level Date Algorithms"); OCaml's stdlib has no [timegm] equivalent,
   so this is the standard hand-rolled replacement. Verified against the
   RFC 9110 example date 1994-11-06 08:49:37 GMT -> epoch 784111777. *)
let days_from_civil ~year ~month ~day =
  let y = if month <= 2 then year - 1 else year in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - (era * 400) in
  let mp = (month + 9) mod 12 in
  let doy = (((153 * mp) + 2) / 5) + day - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468
;;

(* Strict IMF-fixdate parser (RFC 9110 S5.6.7), e.g.
   ["Sun, 06 Nov 1994 08:49:37 GMT"]. Obsolete HTTP-date forms (RFC 850,
   asctime) are not accepted — real Retry-After emitters use delay-seconds
   almost exclusively, and this codebase does not need to interoperate
   with clients emitting the obsolete forms. Never raises: any deviation
   from the exact grammar returns [None]. *)
let parse_imf_fixdate (s : string) : float option =
  match String.split_on_char ' ' s with
  | [ day_name; day_str; month_str; year_str; time_str; "GMT" ] ->
    let day_name_ok = String.length day_name = 4 && day_name.[3] = ',' in
    if
      (not day_name_ok)
      || (not (digits_of_len 2 day_str))
      || not (digits_of_len 4 year_str)
    then None
    else (
      match month_of_abbrev month_str with
      | None -> None
      | Some month ->
        (match String.split_on_char ':' time_str with
         | [ hh; mm; ss ]
           when digits_of_len 2 hh && digits_of_len 2 mm && digits_of_len 2 ss ->
           let day = int_of_string day_str in
           let year = int_of_string year_str in
           let hour = int_of_string hh in
           let minute = int_of_string mm in
           let second = int_of_string ss in
           (* second <= 60 admits the RFC 9110 leap-second allowance. *)
           if day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60
           then None
           else (
             let days = days_from_civil ~year ~month ~day in
             let epoch_seconds =
               (float_of_int days *. 86400.0)
               +. float_of_int ((hour * 3600) + (minute * 60) + second)
             in
             Some epoch_seconds)
         | _ -> None))
  | _ -> None
;;

let parse_seconds ~now (raw : string) : float option =
  let trimmed = String.trim raw in
  if all_digits trimmed
  then (
    match int_of_string_opt trimmed with
    | Some seconds -> Some (float_of_int seconds)
    | None -> None (* overflowed int range; reject rather than guess *))
  else (
    match parse_imf_fixdate trimmed with
    | Some epoch_seconds -> Some (Float.max 0.0 (epoch_seconds -. now))
    | None -> None)
;;

let%test "parse_seconds: delay-seconds" =
  parse_seconds ~now:1_700_000_000.0 "120" = Some 120.0
;;

let%test "parse_seconds: delay-seconds ignores surrounding whitespace" =
  parse_seconds ~now:1_700_000_000.0 " 45 " = Some 45.0
;;

let%test "parse_seconds: negative delay-seconds is malformed" =
  parse_seconds ~now:1_700_000_000.0 "-5" = None
;;

let%test "parse_seconds: HTTP-date in the future yields positive delay" =
  (* now is 100s before the RFC 9110 S5.6.7 example date -> a 100s delay. *)
  parse_seconds ~now:784111677.0 "Sun, 06 Nov 1994 08:49:37 GMT" = Some 100.0
;;

let%test "parse_seconds: HTTP-date in the past clamps to zero" =
  (* now is well after the example date; the naive delay would be
     negative, which must clamp to 0.0 rather than signal "retry in the
     past". *)
  parse_seconds ~now:1_700_000_000.0 "Sun, 06 Nov 1994 08:49:37 GMT"
  = Some 0.0
;;

let%test "parse_seconds: malformed value yields None" =
  parse_seconds ~now:1_700_000_000.0 "not-a-value" = None
;;

let%test "parse_seconds: empty value yields None" =
  parse_seconds ~now:1_700_000_000.0 "" = None
;;

let%test "parse_seconds: RFC 850 obsolete form is rejected" =
  parse_seconds ~now:1_700_000_000.0 "Sunday, 06-Nov-94 08:49:37 GMT" = None
;;
