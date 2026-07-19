(* See .mli for the contract. RFC 5545 VEVENT recurrence identity. *)

module Content_line = Schedule_ical_content_line
module Recur = Schedule_ical_recur

type tzid = string

type dtstart =
  | Start_date of Recur.date
  | Start_local of Recur.date * Recur.time_of_day
  | Start_utc of Recur.date * Recur.time_of_day
  | Start_tzid of tzid * Recur.date * Recur.time_of_day

type range =
  | This_and_future

type recurrence_id =
  { value : dtstart
  ; range : range option
  }

type parameter_error =
  | Duplicate_parameter of
      { property : string
      ; parameter : string
      }
  | Multiple_parameter_values of
      { property : string
      ; parameter : string
      }

type t =
  { uid : string
  ; dtstart : dtstart
  ; recurrence_id : recurrence_id option
  ; rrule : Recur.t option
  }

type parse_error =
  | Missing_uid
  | Duplicate_uid
  | Empty_uid
  | Missing_dtstart
  | Duplicate_dtstart
  | Invalid_dtstart of { value : string; detail : string }
  | Duplicate_recurrence_id
  | Invalid_recurrence_id of { value : string; detail : string }
  | Recurrence_id_value_mismatch
  | Invalid_range of string
  | Parameter_error of parameter_error
  | Duplicate_rrule
  | Rrule_error of Recur.parse_error
  | Until_dtstart_mismatch of { dtstart_form : string; until_form : string }

let parse_error_to_string = function
  | Missing_uid -> "VEVENT recurrence identity requires UID"
  | Duplicate_uid -> "UID occurs more than once"
  | Empty_uid -> "UID must be non-empty"
  | Missing_dtstart -> "VEVENT recurrence identity requires DTSTART"
  | Duplicate_dtstart -> "DTSTART occurs more than once"
  | Invalid_dtstart { value; detail } ->
    Printf.sprintf "invalid DTSTART value %S: %s" value detail
  | Duplicate_recurrence_id -> "RECURRENCE-ID occurs more than once"
  | Invalid_recurrence_id { value; detail } ->
    Printf.sprintf "invalid RECURRENCE-ID value %S: %s" value detail
  | Recurrence_id_value_mismatch ->
    "RECURRENCE-ID value form must match DTSTART's"
  | Invalid_range raw -> Printf.sprintf "invalid RANGE value %S" raw
  | Parameter_error (Duplicate_parameter { property; parameter }) ->
    Printf.sprintf "%s repeats parameter %s" property parameter
  | Parameter_error (Multiple_parameter_values { property; parameter }) ->
    Printf.sprintf "%s parameter %s must have exactly one value" property parameter
  | Duplicate_rrule -> "RRULE occurs more than once"
  | Rrule_error err ->
    Printf.sprintf "RRULE rejected: %s" (Recur.parse_error_to_string err)
  | Until_dtstart_mismatch { dtstart_form; until_form } ->
    Printf.sprintf
      "UNTIL value form %S does not agree with DTSTART value form %S"
      until_form dtstart_form

(* ---------------------------------------------------------------- *)
(* Value parsing                                                    *)
(* ---------------------------------------------------------------- *)

let make_tzid raw =
  if String.equal raw "" then None else Some raw

(* Single-valued parameters only; a multi-valued TZID/VALUE is malformed,
   not absent. *)
let single_param ~property name (line : Content_line.t) =
  match Content_line.find_unique_param ~name line.Content_line.params with
  | Error (Content_line.Duplicate_parameter parameter) ->
    Error (Parameter_error (Duplicate_parameter { property; parameter }))
  | Ok None -> Ok None
  | Ok (Some { Content_line.values = [ raw ]; _ }) -> Ok (Some raw)
  | Ok (Some _) ->
    Error
      (Parameter_error
         (Multiple_parameter_values { property; parameter = name }))

(* A DATE-TIME value: YYYYMMDDTHHMMSS with an optional trailing Z. *)
let parse_datetime raw =
  let n = String.length raw in
  if n = 15 && raw.[8] = 'T' then (
    match
      ( Recur.parse_date_value (String.sub raw 0 8)
      , Recur.parse_time_of_day_value (String.sub raw 9 6) )
    with
    | Ok d, Ok t -> Ok (`Local (d, t))
    | _ -> Error "expected YYYYMMDDTHHMMSS")
  else if n = 16 && raw.[8] = 'T' && raw.[15] = 'Z' then (
    match
      ( Recur.parse_date_value (String.sub raw 0 8)
      , Recur.parse_time_of_day_value (String.sub raw 9 6) )
    with
    | Ok d, Ok t -> Ok (`Utc (d, t))
    | _ -> Error "expected YYYYMMDDTHHMMSSZ")
  else Error "expected YYYYMMDDTHHMMSS[Z]"

let parse_dtstart_like ~property ~invalid (line : Content_line.t) =
  let ( let* ) = Result.bind in
  let value = line.Content_line.value in
  let reject detail = Error (invalid ~value ~detail) in
  let* value_parameter = single_param ~property "VALUE" line in
  let* tzid_parameter = single_param ~property "TZID" line in
  match Option.map String.uppercase_ascii value_parameter with
  | Some "DATE" -> (
    match tzid_parameter with
    | Some _ -> reject "TZID parameter on a DATE value"
    | None ->
    match Recur.parse_date_value value with
    | Ok d -> Ok (Start_date d)
    | Error err -> reject (Recur.parse_error_to_string err))
  | Some "DATE-TIME" | None -> (
    match parse_datetime value with
    | Error detail -> reject detail
    | Ok (`Utc (d, t)) ->
      (match tzid_parameter with
       | Some _ -> reject "TZID parameter on a UTC value"
       | None -> Ok (Start_utc (d, t)))
    | Ok (`Local (d, t)) ->
      (match tzid_parameter with
       | Some raw -> (
        match make_tzid raw with
        | Some tzid -> Ok (Start_tzid (tzid, d, t))
        | None -> reject "TZID parameter is empty")
       | None -> Ok (Start_local (d, t))))
  | Some raw_value -> reject (Printf.sprintf "unsupported VALUE=%s" raw_value)

let parse_range (line : Content_line.t) =
  match single_param ~property:"RECURRENCE-ID" "RANGE" line with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some raw) ->
    if String.equal (String.uppercase_ascii raw) "THISANDFUTURE" then
      Ok (Some This_and_future)
    else Error (Invalid_range raw)

let same_form a b =
  match a, b with
  | Start_date _, Start_date _ -> true
  | Start_local _, Start_local _ -> true
  | Start_utc _, Start_utc _ -> true
  | Start_tzid (tz_a, _, _), Start_tzid (tz_b, _, _) -> String.equal tz_a tz_b
  | _ -> false

let form_label = function
  | Start_date _ -> "date"
  | Start_local _ -> "local"
  | Start_utc _ -> "utc"
  | Start_tzid _ -> "tzid"

let until_form_label (until : Recur.until) =
  match until with
  | Recur.Until_date _ -> "date"
  | Recur.Until_local _ -> "local"
  | Recur.Until_utc _ -> "utc"

(* §3.3.10: UNTIL agrees with DTSTART — DATE with DATE, floating local with
   local, UTC or TZID-referenced DTSTART with UTC. *)
let until_agrees ~dtstart (until : Recur.until) =
  match dtstart, until with
  | Start_date _, Recur.Until_date _ -> true
  | Start_local _, Recur.Until_local _ -> true
  | Start_utc _, Recur.Until_utc _ -> true
  | Start_tzid _, Recur.Until_utc _ -> true
  | _ -> false

(* ---------------------------------------------------------------- *)
(* Assembly                                                         *)
(* ---------------------------------------------------------------- *)

type builder =
  { b_uid : string option
  ; b_dtstart : dtstart option
  ; b_recurrence_id : recurrence_id option
  ; b_rrule : Recur.t option
  }

let empty = { b_uid = None; b_dtstart = None; b_recurrence_id = None; b_rrule = None }

let apply (line : Content_line.t) b =
  match line.Content_line.name with
  | "UID" -> (
    match b.b_uid with
    | Some _ -> Error Duplicate_uid
    | None ->
      let uid = line.Content_line.value in
      if String.equal uid "" then Error Empty_uid
      else Ok { b with b_uid = Some uid })
  | "DTSTART" -> (
    match b.b_dtstart with
    | Some _ -> Error Duplicate_dtstart
    | None -> (
      match
        parse_dtstart_like
          ~property:"DTSTART"
          ~invalid:(fun ~value ~detail -> Invalid_dtstart { value; detail })
          line
      with
      | Error _ as error -> error
      | Ok dtstart -> Ok { b with b_dtstart = Some dtstart }))
  | "RECURRENCE-ID" -> (
    match b.b_recurrence_id with
    | Some _ -> Error Duplicate_recurrence_id
    | None -> (
      match
        parse_dtstart_like
          ~property:"RECURRENCE-ID"
          ~invalid:(fun ~value ~detail -> Invalid_recurrence_id { value; detail })
          line
      with
      | Error _ as error -> error
      | Ok value -> (
        match parse_range line with
        | Error _ as error -> error
        | Ok range ->
          Ok { b with b_recurrence_id = Some { value; range } })))
  | "RRULE" -> (
    match b.b_rrule with
    | Some _ -> Error Duplicate_rrule
    | None -> (
      match Recur.parse line.Content_line.value with
      | Error err -> Error (Rrule_error err)
      | Ok rrule -> Ok { b with b_rrule = Some rrule }))
  | _ -> Ok b

let parse lines =
  let rec loop b = function
    | [] -> (
      match b.b_uid with
      | None -> Error Missing_uid
      | Some uid -> (
        match b.b_dtstart with
        | None -> Error Missing_dtstart
        | Some dtstart -> (
          match b.b_recurrence_id with
          | Some rid when not (same_form rid.value dtstart) ->
            Error Recurrence_id_value_mismatch
          | _ -> (
            match b.b_rrule with
            | Some rrule -> (
              match rrule.Recur.bound with
              | Recur.Until until
                when not (until_agrees ~dtstart until) ->
                Error
                  (Until_dtstart_mismatch
                     { dtstart_form = form_label dtstart
                     ; until_form = until_form_label until
                     })
              | _ ->
                Ok
                  { uid
                  ; dtstart
                  ; recurrence_id = b.b_recurrence_id
                  ; rrule = Some rrule
                  })
            | None ->
              Ok
                { uid
                ; dtstart
                ; recurrence_id = b.b_recurrence_id
                ; rrule = None
                }))))
    | line :: rest -> (
      match apply line b with
      | Error _ as error -> error
      | Ok b -> loop b rest)
  in
  loop empty lines
