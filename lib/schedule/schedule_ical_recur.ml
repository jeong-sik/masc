(* See .mli for the contract. RFC 5545 §3.3.10 RECUR value type. *)

type freq = Secondly | Minutely | Hourly | Daily | Weekly | Monthly | Yearly

type weekday =
  | Sunday | Monday | Tuesday | Wednesday | Thursday | Friday | Saturday

type weekday_num = { ordinal : int option; day : weekday }
type date = { year : int; month : int; day : int }
type time_of_day = { hour : int; minute : int; second : int }

type until =
  | Until_date of date
  | Until_local of date * time_of_day
  | Until_utc of date * time_of_day

type bound =
  | Forever
  | Count of int
  | Until of until

type t =
  { freq : freq
  ; bound : bound
  ; interval : int
  ; bysecond : int list
  ; byminute : int list
  ; byhour : int list
  ; byday : weekday_num list
  ; bymonthday : int list
  ; byyearday : int list
  ; byweekno : int list
  ; bymonth : int list
  ; bysetpos : int list
  ; wkst : weekday
  }

type parse_error =
  | Empty_part
  | Missing_equals of string
  | Unknown_part of string
  | Duplicate_part of string
  | Missing_freq
  | Invalid_freq of string
  | Invalid_number of { part : string; value : string }
  | Out_of_range of { part : string; value : int; min : int; max : int }
  | Invalid_date of string
  | Invalid_time of string
  | Invalid_until of string
  | Invalid_weekday of string
  | Until_count_conflict
  | Numeric_byday_not_allowed of freq
  | Numeric_byday_with_byweekno
  | Bymonthday_with_weekly
  | Byyearday_not_allowed of freq
  | Byweekno_not_allowed of freq
  | Bysetpos_without_byxxx

(* ---------------------------------------------------------------- *)
(* Small total parsers                                              *)
(* ---------------------------------------------------------------- *)

let is_digit c = Char.code c >= Char.code '0' && Char.code c <= Char.code '9'

let all_digits s =
  let n = String.length s in
  n > 0
  &&
  let rec loop i = i >= n || (is_digit s.[i] && loop (i + 1)) in
  loop 0

let parse_digits ~part value =
  if all_digits value then
    match int_of_string_opt value with
    | Some n -> Ok n
    | None -> Error (Invalid_number { part; value })
  else Error (Invalid_number { part; value })

(* Grammar-signed integers: one optional [+/-] then digits. *)
let parse_signed ~part value =
  let n = String.length value in
  let body, negative =
    if n > 0 && value.[0] = '-' then
      (String.sub value 1 (n - 1), true)
    else if n > 0 && value.[0] = '+' then
      (String.sub value 1 (n - 1), false)
    else (value, false)
  in
  match parse_digits ~part body with
  | Error _ -> Error (Invalid_number { part; value })
  | Ok magnitude -> Ok (if negative then -magnitude else magnitude)

let check_range ~part ~min ~max value =
  if value >= min && value <= max then Ok value
  else Error (Out_of_range { part; value; min; max })

(* ---------------------------------------------------------------- *)
(* Date / time validation (proleptic Gregorian)                     *)
(* ---------------------------------------------------------------- *)

let is_leap_year year =
  year mod 4 = 0 && (year mod 100 <> 0 || year mod 400 = 0)

let days_in_month year month =
  match month with
  | 1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
  | 4 | 6 | 9 | 11 -> 30
  | 2 -> if is_leap_year year then 29 else 28
  | _ -> 0

let valid_date year month day =
  month >= 1 && month <= 12 && day >= 1 && day <= days_in_month year month

let parse_date raw =
  if String.length raw = 8 && all_digits raw then begin
    let year = int_of_string (String.sub raw 0 4) in
    let month = int_of_string (String.sub raw 4 2) in
    let day = int_of_string (String.sub raw 6 2) in
    if valid_date year month day then Ok { year; month; day }
    else Error (Invalid_date raw)
  end
  else Error (Invalid_date raw)

let parse_time_of_day raw =
  if String.length raw = 6 && all_digits raw then begin
    let hour = int_of_string (String.sub raw 0 2) in
    let minute = int_of_string (String.sub raw 2 2) in
    let second = int_of_string (String.sub raw 4 2) in
    if hour <= 23 && minute <= 59 && second <= 60 then
      Ok { hour; minute; second }
    else Error (Invalid_time raw)
  end
  else Error (Invalid_time raw)

let parse_date_value = parse_date
let parse_time_of_day_value = parse_time_of_day

let parse_until raw =
  let n = String.length raw in
  if n = 8 then
    match parse_date raw with
    | Error _ as error -> error
    | Ok d -> Ok (Until_date d)
  else if n = 15 && raw.[8] = 'T' then
    (match parse_date (String.sub raw 0 8) with
     | Error _ as error -> error
     | Ok d ->
       (match parse_time_of_day (String.sub raw 9 6) with
        | Error _ as error -> error
        | Ok t -> Ok (Until_local (d, t))))
  else if n = 16 && raw.[8] = 'T' && raw.[15] = 'Z' then
    (match parse_date (String.sub raw 0 8) with
     | Error _ as error -> error
     | Ok d ->
       (match parse_time_of_day (String.sub raw 9 6) with
        | Error _ as error -> error
        | Ok t -> Ok (Until_utc (d, t))))
  else Error (Invalid_until raw)

(* ---------------------------------------------------------------- *)
(* Enumerations                                                     *)
(* ---------------------------------------------------------------- *)

let freq_of_string = function
  | "SECONDLY" -> Ok Secondly
  | "MINUTELY" -> Ok Minutely
  | "HOURLY" -> Ok Hourly
  | "DAILY" -> Ok Daily
  | "WEEKLY" -> Ok Weekly
  | "MONTHLY" -> Ok Monthly
  | "YEARLY" -> Ok Yearly
  | other -> Error (Invalid_freq other)

let freq_to_string = function
  | Secondly -> "SECONDLY"
  | Minutely -> "MINUTELY"
  | Hourly -> "HOURLY"
  | Daily -> "DAILY"
  | Weekly -> "WEEKLY"
  | Monthly -> "MONTHLY"
  | Yearly -> "YEARLY"

let weekday_of_string = function
  | "SU" -> Ok Sunday
  | "MO" -> Ok Monday
  | "TU" -> Ok Tuesday
  | "WE" -> Ok Wednesday
  | "TH" -> Ok Thursday
  | "FR" -> Ok Friday
  | "SA" -> Ok Saturday
  | other -> Error (Invalid_weekday other)

let weekday_to_string = function
  | Sunday -> "SU"
  | Monday -> "MO"
  | Tuesday -> "TU"
  | Wednesday -> "WE"
  | Thursday -> "TH"
  | Friday -> "FR"
  | Saturday -> "SA"

(* ---------------------------------------------------------------- *)
(* BYxxx list elements                                              *)
(* ---------------------------------------------------------------- *)

let split_list ~part raw =
  let items = String.split_on_char ',' raw in
  if List.exists (fun item -> String.length item = 0) items then
    Error (Invalid_number { part; value = raw })
  else Ok items

let map_list items ~f =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest -> (
      match f item with
      | Error _ as error -> error
      | Ok value -> loop (value :: acc) rest)
  in
  loop [] items

let parse_int_list ~part ~min ~max ~max_digits raw =
  match split_list ~part raw with
  | Error _ as error -> error
  | Ok items ->
    map_list items ~f:(fun item ->
      (* Grammar digit caps ([seconds]/[minutes]/[hour]/... are 1*2DIGIT,
         [ordyrday] is 1*3DIGIT): excess digits are rejected, not
         normalized. *)
      if String.length item > max_digits then
        Error (Invalid_number { part; value = item })
      else
        match parse_digits ~part item with
        | Error _ as error -> error
        | Ok n -> check_range ~part ~min ~max n)

let parse_signed_list ~part ~min ~max ~max_digits raw =
  match split_list ~part raw with
  | Error _ as error -> error
  | Ok items ->
    map_list items ~f:(fun item ->
      let digit_len =
        if String.length item > 0 && (item.[0] = '+' || item.[0] = '-')
        then String.length item - 1
        else String.length item
      in
      if digit_len > max_digits then
        Error (Invalid_number { part; value = item })
      else
        match parse_signed ~part item with
        | Error _ as error -> error
        | Ok n -> check_range ~part ~min ~max n)

let parse_weekday_num raw =
  (* [[plus / minus] ordwk] weekday — optional signed ordinal, then a
     two-letter weekday token. *)
  let n = String.length raw in
  let sign_len =
    if n > 0 && (raw.[0] = '+' || raw.[0] = '-') then 1 else 0
  in
  let digit_end =
    let rec loop i = if i < n && is_digit raw.[i] then loop (i + 1) else i in
    loop sign_len
  in
  let ordinal_raw = String.sub raw 0 digit_end in
  let weekday_raw = String.sub raw digit_end (n - digit_end) in
  if digit_end - sign_len > 2 then
    (* [ordwk] is 1*2DIGIT: [001MO] is a grammar violation, not [1MO]. *)
    Error (Invalid_number { part = "BYDAY"; value = raw })
  else
  match weekday_of_string (String.uppercase_ascii weekday_raw) with
  | Error _ as error -> error
  | Ok day -> (
    if String.length ordinal_raw = 0 then Ok { ordinal = None; day }
    else
      match parse_signed ~part:"BYDAY" ordinal_raw with
      | Error _ as error -> error
      | Ok ord -> (
        match check_range ~part:"BYDAY" ~min:(-53) ~max:53 ord with
        | Error _ as error -> error
        | Ok _ ->
          if ord = 0 then
            Error
              (Out_of_range { part = "BYDAY"; value = 0; min = -53; max = 53 })
          else Ok { ordinal = Some ord; day }))

let parse_byday raw =
  match split_list ~part:"BYDAY" raw with
  | Error _ as error -> error
  | Ok items -> map_list items ~f:parse_weekday_num

(* ---------------------------------------------------------------- *)
(* Part assembly                                                    *)
(* ---------------------------------------------------------------- *)

(* Accumulator: [None] means the part has not occurred yet, so a second
   occurrence is detected exactly (§3.3.10: each part at most once). *)
type builder =
  { b_freq : freq option
  ; b_until : until option
  ; b_count : int option
  ; b_interval : int option
  ; b_bysecond : int list option
  ; b_byminute : int list option
  ; b_byhour : int list option
  ; b_byday : weekday_num list option
  ; b_bymonthday : int list option
  ; b_byyearday : int list option
  ; b_byweekno : int list option
  ; b_bymonth : int list option
  ; b_bysetpos : int list option
  ; b_wkst : weekday option
  }

let empty_builder =
  { b_freq = None
  ; b_until = None
  ; b_count = None
  ; b_interval = None
  ; b_bysecond = None
  ; b_byminute = None
  ; b_byhour = None
  ; b_byday = None
  ; b_bymonthday = None
  ; b_byyearday = None
  ; b_byweekno = None
  ; b_bymonth = None
  ; b_bysetpos = None
  ; b_wkst = None
  }

(* [via parse ~slot ~update] threads one rule part: a prior occurrence of
   the same part is [Duplicate_part] (§3.3.10: each part at most once), a
   parse failure propagates, and success stores the value in the builder. *)
let apply_part builder name raw_value =
  let via parse ~slot ~update =
    match slot with
    | Some _ -> Error (Duplicate_part name)
    | None ->
      (match parse () with
       | Error _ as error -> error
       | Ok value -> Ok (update value))
  in
  let nonzero ~min ~max values =
    if List.exists (fun n -> n = 0) values then
      Error (Out_of_range { part = name; value = 0; min; max })
    else Ok values
  in
  let positive_int () =
    match parse_digits ~part:name raw_value with
    | Error _ as error -> error
    | Ok n -> check_range ~part:name ~min:1 ~max:max_int n
  in
  match name with
  | "FREQ" ->
    via (fun () -> freq_of_string (String.uppercase_ascii raw_value))
      ~slot:builder.b_freq
      ~update:(fun v -> { builder with b_freq = Some v })
  | "UNTIL" ->
    via (fun () -> parse_until raw_value) ~slot:builder.b_until
      ~update:(fun v -> { builder with b_until = Some v })
  | "COUNT" ->
    via positive_int ~slot:builder.b_count
      ~update:(fun v -> { builder with b_count = Some v })
  | "INTERVAL" ->
    via positive_int ~slot:builder.b_interval
      ~update:(fun v -> { builder with b_interval = Some v })
  | "BYSECOND" ->
    via
      (fun () ->
        parse_int_list ~part:name ~min:0 ~max:60 ~max_digits:2 raw_value)
      ~slot:builder.b_bysecond
      ~update:(fun v -> { builder with b_bysecond = Some v })
  | "BYMINUTE" ->
    via
      (fun () ->
        parse_int_list ~part:name ~min:0 ~max:59 ~max_digits:2 raw_value)
      ~slot:builder.b_byminute
      ~update:(fun v -> { builder with b_byminute = Some v })
  | "BYHOUR" ->
    via
      (fun () ->
        parse_int_list ~part:name ~min:0 ~max:23 ~max_digits:2 raw_value)
      ~slot:builder.b_byhour
      ~update:(fun v -> { builder with b_byhour = Some v })
  | "BYDAY" ->
    via (fun () -> parse_byday raw_value) ~slot:builder.b_byday
      ~update:(fun v -> { builder with b_byday = Some v })
  | "BYMONTHDAY" ->
    via
      (fun () ->
        match
          parse_signed_list ~part:name ~min:(-31) ~max:31 ~max_digits:2
            raw_value
        with
        | Error _ as error -> error
        | Ok values -> nonzero ~min:(-31) ~max:31 values)
      ~slot:builder.b_bymonthday
      ~update:(fun v -> { builder with b_bymonthday = Some v })
  | "BYYEARDAY" ->
    via
      (fun () ->
        match
          parse_signed_list ~part:name ~min:(-366) ~max:366 ~max_digits:3
            raw_value
        with
        | Error _ as error -> error
        | Ok values -> nonzero ~min:(-366) ~max:366 values)
      ~slot:builder.b_byyearday
      ~update:(fun v -> { builder with b_byyearday = Some v })
  | "BYWEEKNO" ->
    via
      (fun () ->
        match
          parse_signed_list ~part:name ~min:(-53) ~max:53 ~max_digits:2 raw_value
        with
        | Error _ as error -> error
        | Ok values -> nonzero ~min:(-53) ~max:53 values)
      ~slot:builder.b_byweekno
      ~update:(fun v -> { builder with b_byweekno = Some v })
  | "BYMONTH" ->
    via
      (fun () ->
        parse_int_list ~part:name ~min:1 ~max:12 ~max_digits:2 raw_value)
      ~slot:builder.b_bymonth
      ~update:(fun v -> { builder with b_bymonth = Some v })
  | "BYSETPOS" ->
    via
      (fun () ->
        match
          parse_signed_list ~part:name ~min:(-366) ~max:366 ~max_digits:3
            raw_value
        with
        | Error _ as error -> error
        | Ok values -> nonzero ~min:(-366) ~max:366 values)
      ~slot:builder.b_bysetpos
      ~update:(fun v -> { builder with b_bysetpos = Some v })
  | "WKST" ->
    via (fun () -> weekday_of_string (String.uppercase_ascii raw_value))
      ~slot:builder.b_wkst
      ~update:(fun v -> { builder with b_wkst = Some v })
  | _ -> Error (Unknown_part name)

(* Cross-part semantic constraints (§3.3.10 prose). Each rule is a typed
   error; none is silently dropped or defaulted away. Absent [BYxxx] parts
   are exactly the empty list (the RFC assigns them no default), and
   [INTERVAL]=1 / [WKST]=MO are the RFC-mandated defaults — written out as
   explicit matches, not catch-all fallbacks. *)
let assemble_with_bound freq (b : builder) bound =
  let list_of = function Some values -> values | None -> [] in
  let byday = list_of b.b_byday in
  let bymonthday = list_of b.b_bymonthday in
  let byyearday = list_of b.b_byyearday in
  let byweekno = list_of b.b_byweekno in
  let bysetpos = list_of b.b_bysetpos in
  let has_numeric_byday =
    List.exists (fun (wn : weekday_num) -> Option.is_some wn.ordinal) byday
  in
  if has_numeric_byday && freq <> Monthly && freq <> Yearly then
    Error (Numeric_byday_not_allowed freq)
  else if has_numeric_byday && freq = Yearly && byweekno <> [] then
    Error Numeric_byday_with_byweekno
  else if bymonthday <> [] && freq = Weekly then
    Error Bymonthday_with_weekly
  else if byyearday <> [] && (freq = Daily || freq = Weekly || freq = Monthly)
  then Error (Byyearday_not_allowed freq)
  else if byweekno <> [] && freq <> Yearly then
    Error (Byweekno_not_allowed freq)
  else if
    bysetpos <> []
    && list_of b.b_bysecond = []
    && list_of b.b_byminute = []
    && list_of b.b_byhour = []
    && byday = []
    && bymonthday = []
    && byyearday = []
    && byweekno = []
    && list_of b.b_bymonth = []
  then Error Bysetpos_without_byxxx
  else
    Ok
      { freq
      ; bound
      ; interval = (match b.b_interval with Some n -> n | None -> 1)
      ; bysecond = list_of b.b_bysecond
      ; byminute = list_of b.b_byminute
      ; byhour = list_of b.b_byhour
      ; byday
      ; bymonthday
      ; byyearday
      ; byweekno
      ; bymonth = list_of b.b_bymonth
      ; bysetpos
      ; wkst = (match b.b_wkst with Some day -> day | None -> Monday)
      }

let assemble (b : builder) : (t, parse_error) result =
  match b.b_freq with
  | None -> Error Missing_freq
  | Some freq -> (
    match b.b_until, b.b_count with
    | Some _, Some _ -> Error Until_count_conflict
    | Some until, None -> assemble_with_bound freq b (Until until)
    | None, Some count -> assemble_with_bound freq b (Count count)
    | None, None -> assemble_with_bound freq b Forever)

let parse value =
  let parts = String.split_on_char ';' value in
  let rec loop builder = function
    | [] -> assemble builder
    | part :: rest -> (
      if String.length part = 0 then Error Empty_part
      else
        match String.index_opt part '=' with
        | None -> Error (Missing_equals part)
        | Some eq ->
          let name = String.uppercase_ascii (String.sub part 0 eq) in
          let raw_value =
            String.sub part (eq + 1) (String.length part - eq - 1)
          in
          (match apply_part builder name raw_value with
           | Error _ as error -> error
           | Ok builder -> loop builder rest))
  in
  loop empty_builder parts

(* ---------------------------------------------------------------- *)
(* Canonical serialization                                          *)
(* ---------------------------------------------------------------- *)

let date_to_string { year; month; day } =
  Printf.sprintf "%04d%02d%02d" year month day

let time_to_string { hour; minute; second } =
  Printf.sprintf "%02d%02d%02d" hour minute second

let until_to_string = function
  | Until_date d -> date_to_string d
  | Until_local (d, t) -> date_to_string d ^ "T" ^ time_to_string t
  | Until_utc (d, t) -> date_to_string d ^ "T" ^ time_to_string t ^ "Z"

let int_list_to_string values = String.concat "," (List.map string_of_int values)

let weekday_num_to_string { ordinal; day } =
  match ordinal with
  | None -> weekday_to_string day
  | Some n -> string_of_int n ^ weekday_to_string day

let to_string t =
  let parts = ref [ "FREQ=" ^ freq_to_string t.freq ] in
  (match t.bound with
   | Forever -> ()
   | Count n -> parts := !parts @ [ "COUNT=" ^ string_of_int n ]
   | Until until -> parts := !parts @ [ "UNTIL=" ^ until_to_string until ]);
  parts := !parts @ [ "INTERVAL=" ^ string_of_int t.interval ];
  if t.bysecond <> [] then
    parts := !parts @ [ "BYSECOND=" ^ int_list_to_string t.bysecond ];
  if t.byminute <> [] then
    parts := !parts @ [ "BYMINUTE=" ^ int_list_to_string t.byminute ];
  if t.byhour <> [] then
    parts := !parts @ [ "BYHOUR=" ^ int_list_to_string t.byhour ];
  if t.byday <> [] then
    parts :=
      !parts @ [ "BYDAY=" ^ String.concat "," (List.map weekday_num_to_string t.byday) ];
  if t.bymonthday <> [] then
    parts := !parts @ [ "BYMONTHDAY=" ^ int_list_to_string t.bymonthday ];
  if t.byyearday <> [] then
    parts := !parts @ [ "BYYEARDAY=" ^ int_list_to_string t.byyearday ];
  if t.byweekno <> [] then
    parts := !parts @ [ "BYWEEKNO=" ^ int_list_to_string t.byweekno ];
  if t.bymonth <> [] then
    parts := !parts @ [ "BYMONTH=" ^ int_list_to_string t.bymonth ];
  if t.bysetpos <> [] then
    parts := !parts @ [ "BYSETPOS=" ^ int_list_to_string t.bysetpos ];
  parts := !parts @ [ "WKST=" ^ weekday_to_string t.wkst ];
  String.concat ";" !parts

(* ---------------------------------------------------------------- *)
(* Diagnostics                                                      *)
(* ---------------------------------------------------------------- *)

let parse_error_to_string = function
  | Empty_part -> "empty rule part (a ;; run or leading/trailing ;)"
  | Missing_equals part -> Printf.sprintf "rule part %S has no = separator" part
  | Unknown_part name -> Printf.sprintf "unknown rule part %S" name
  | Duplicate_part name -> Printf.sprintf "duplicate rule part %S" name
  | Missing_freq -> "FREQ rule part is required"
  | Invalid_freq value -> Printf.sprintf "invalid FREQ value %S" value
  | Invalid_number { part; value } ->
    Printf.sprintf "%s: invalid number %S" part value
  | Out_of_range { part; value; min; max } ->
    Printf.sprintf "%s: value %d out of range %d..%d" part value min max
  | Invalid_date value -> Printf.sprintf "invalid date %S" value
  | Invalid_time value -> Printf.sprintf "invalid time %S" value
  | Invalid_until value -> Printf.sprintf "invalid UNTIL value %S" value
  | Invalid_weekday value -> Printf.sprintf "invalid weekday %S" value
  | Until_count_conflict -> "UNTIL and COUNT must not occur in the same recur"
  | Numeric_byday_not_allowed freq ->
    Printf.sprintf
      "numeric BYDAY is only allowed with FREQ=MONTHLY or FREQ=YEARLY (got %s)"
      (freq_to_string freq)
  | Numeric_byday_with_byweekno ->
    "numeric BYDAY with FREQ=YEARLY forbids BYWEEKNO"
  | Bymonthday_with_weekly -> "BYMONTHDAY is not allowed with FREQ=WEEKLY"
  | Byyearday_not_allowed freq ->
    Printf.sprintf "BYYEARDAY is not allowed with FREQ=%s"
      (freq_to_string freq)
  | Byweekno_not_allowed freq ->
    Printf.sprintf "BYWEEKNO is only allowed with FREQ=YEARLY (got %s)"
      (freq_to_string freq)
  | Bysetpos_without_byxxx -> "BYSETPOS requires another BYxxx rule part"
