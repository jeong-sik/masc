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
  | This_and_prior
  | This_and_future

type recurrence_id =
  { value : dtstart
  ; range : range
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
  let trimmed = String.trim raw in
  if String.equal trimmed "" then None else Some trimmed

(* Single-valued parameters only; a multi-valued TZID/VALUE is malformed,
   not absent. *)
let single_param name (line : Content_line.t) =
  match Content_line.find_param ~name line.Content_line.params with
  | None -> Ok None
  | Some { Content_line.values = [ raw ]; _ } -> Ok (Some raw)
  | Some _ -> Error (Printf.sprintf "%s parameter has multiple values" name)

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

let parse_dtstart_like (line : Content_line.t) =
  let value = line.Content_line.value in
  let invalid detail = Error (value, detail) in
  match single_param "VALUE" line with
  | Error detail -> invalid detail
  | Ok (Some raw_value) when not (String.equal (String.uppercase_ascii raw_value) "DATE") ->
    invalid (Printf.sprintf "unsupported VALUE=%s" raw_value)
  | Ok (Some _) -> (
    match Recur.parse_date_value value with
    | Ok d -> Ok (Start_date d)
    | Error err -> invalid (Recur.parse_error_to_string err))
  | Ok None -> (
    match parse_datetime value with
    | Error detail -> invalid detail
    | Ok (`Utc (d, t)) -> (
      match single_param "TZID" line with
      | Error detail -> invalid detail
      | Ok (Some _) -> invalid "TZID parameter on a UTC value"
      | Ok None -> Ok (Start_utc (d, t)))
    | Ok (`Local (d, t)) -> (
      match single_param "TZID" line with
      | Error detail -> invalid detail
      | Ok (Some raw) -> (
        match make_tzid raw with
        | Some tzid -> Ok (Start_tzid (tzid, d, t))
        | None -> invalid "TZID parameter is empty")
      | Ok None -> Ok (Start_local (d, t))))

let parse_range (line : Content_line.t) =
  match Content_line.find_param ~name:"RANGE" line.Content_line.params with
  | None -> Ok This_and_prior
  | Some { Content_line.values = [ raw ]; _ } -> (
    match String.uppercase_ascii raw with
    | "THISANDPRIOR" -> Ok This_and_prior
    | "THISANDFUTURE" -> Ok This_and_future
    | other -> Error other)
  | Some _ -> Error "multiple RANGE values"

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
      let uid = String.trim line.Content_line.value in
      if String.equal uid "" then Error Empty_uid
      else Ok { b with b_uid = Some uid })
  | "DTSTART" -> (
    match b.b_dtstart with
    | Some _ -> Error Duplicate_dtstart
    | None -> (
      match parse_dtstart_like line with
      | Error (value, detail) -> Error (Invalid_dtstart { value; detail })
      | Ok dtstart -> Ok { b with b_dtstart = Some dtstart }))
  | "RECURRENCE-ID" -> (
    match b.b_recurrence_id with
    | Some _ -> Error Duplicate_recurrence_id
    | None -> (
      match parse_dtstart_like line with
      | Error (value, detail) ->
        Error (Invalid_recurrence_id { value; detail })
      | Ok value -> (
        match parse_range line with
        | Error raw -> Error (Invalid_range raw)
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
