type actor_kind =
  | Human_operator
  | Automated_actor
  | System

type actor =
  { id : string
  ; kind : actor_kind
  ; display_name : string option
  }

type schedule_status =
  | Scheduled
  | Due
  | Running
  | Succeeded
  | Failed
  | Cancelled
  | Expired

let all_schedule_statuses =
  [ Scheduled
  ; Due
  ; Running
  ; Succeeded
  ; Failed
  ; Cancelled
  ; Expired
  ]
;;

type schedule_source =
  | Operator_request
  | Automated_request
  | System_request

type recurrence =
  | One_shot
  | Interval of { interval_sec : int }
  | Daily of
      { hour : int
      ; minute : int
      ; second : int
      ; timezone : string
      }
  | Cron of
      { expression : string
      ; timezone : string
      }

type recurrence_evaluation =
  | Next_due_at of float
  | No_next

type recurrence_evaluation_error =
  | Invalid_persisted_recurrence of string
  | Unsupported_timezone of string
  | Engine_failure of string

type payload =
  { kind : string
  ; schema_version : int
  ; body : Yojson.Safe.t
  }

type schedule_request =
  { schedule_id : string
  ; requested_by : actor
  ; scheduled_by : actor
  ; requested_at : float
  ; due_at : float
  ; expires_at : float option
  ; payload : payload
  ; status : schedule_status
  ; source : schedule_source
  ; recurrence : recurrence
  }

type execution_status =
  | Execution_running
  | Execution_succeeded
  | Execution_failed

type execution_record =
  { execution_id : string
  ; schedule_id : string
  ; started_at : float
  ; finished_at : float option
  ; due_at : float
  ; payload_digest : string
  ; status : execution_status
  ; detail : Yojson.Safe.t option
  ; error : string option
  }

let ( let* ) = Result.bind

let nonempty field value =
  if String.trim value = "" then Error (field ^ " must be non-empty") else Ok value
;;

let actor_kind_to_string = function
  | Human_operator -> "human_operator"
  | Automated_actor -> "automated_actor"
  | System -> "system"
;;

let actor_kind_of_string = function
  | "human_operator" -> Ok Human_operator
  | "automated_actor" -> Ok Automated_actor
  | "system" -> Ok System
  | other -> Error ("unknown actor_kind: " ^ other)
;;

let schedule_status_to_string = function
  | Scheduled -> "scheduled"
  | Due -> "due"
  | Running -> "running"
  | Succeeded -> "succeeded"
  | Failed -> "failed"
  | Cancelled -> "cancelled"
  | Expired -> "expired"
;;

let schedule_status_of_string = function
  | "scheduled" -> Ok Scheduled
  | "due" -> Ok Due
  | "running" -> Ok Running
  | "succeeded" -> Ok Succeeded
  | "failed" -> Ok Failed
  | "cancelled" -> Ok Cancelled
  | "expired" -> Ok Expired
  | other -> Error ("unknown schedule_status: " ^ other)
;;

let schedule_source_to_string = function
  | Operator_request -> "operator_request"
  | Automated_request -> "automated_request"
  | System_request -> "system_request"
;;

let schedule_source_of_string = function
  | "operator_request" -> Ok Operator_request
  | "automated_request" -> Ok Automated_request
  | "system_request" -> Ok System_request
  | other -> Error ("unknown schedule_source: " ^ other)
;;

let recurrence_kind_to_string = function
  | One_shot -> "one_shot"
  | Interval _ -> "interval"
  | Daily _ -> "daily"
  | Cron _ -> "cron"
;;

let recurrence_summary = function
  | One_shot -> "one_shot"
  | Interval { interval_sec } -> Printf.sprintf "every %ds" interval_sec
  | Daily { hour; minute; second; timezone } ->
    Printf.sprintf "daily %02d:%02d:%02d %s" hour minute second timezone
  | Cron { expression; timezone } -> Printf.sprintf "cron %s %s" expression timezone
;;

let execution_status_to_string = function
  | Execution_running -> "running"
  | Execution_succeeded -> "succeeded"
  | Execution_failed -> "failed"
;;

let execution_status_of_string = function
  | "running" -> Ok Execution_running
  | "succeeded" -> Ok Execution_succeeded
  | "failed" -> Ok Execution_failed
  | other -> Error ("unknown execution_status: " ^ other)
;;

let is_terminal = function
  | Succeeded | Failed | Cancelled | Expired -> true
  | Scheduled | Due | Running -> false
;;

let is_recurring = function
  | One_shot -> false
  | Interval _ | Daily _ | Cron _ -> true
;;

let rec canonical_json = function
  | `Assoc fields ->
    fields
    |> List.map (fun (key, value) -> key, canonical_json value)
    |> List.sort (fun (left, _) (right, _) -> String.compare left right)
    |> fun fields -> `Assoc fields
  | `List items -> `List (List.map canonical_json items)
  | other -> other
;;

let sha256_json json =
  json |> canonical_json |> Yojson.Safe.to_string
  |> Digestif.SHA256.(fun stable -> digest_string stable |> to_hex)
;;

let option_to_yojson f = function
  | None -> `Null
  | Some value -> f value
;;

let string_option_of_yojson = function
  | `Null -> Ok None
  | `String value -> Ok (Some value)
  | _ -> Error "expected string option"
;;

let float_to_yojson value = `Float value

let float_of_yojson = function
  | `Float value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | _ -> Error "expected float"
;;

let int_of_yojson = function
  | `Int value -> Ok value
  | _ -> Error "expected int"
;;

let assoc_field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("missing field: " ^ name)
;;

let string_field name fields =
  let* value = assoc_field name fields in
  match value with
  | `String value -> Ok value
  | _ -> Error ("expected string field: " ^ name)
;;

let float_field name fields =
  let* value = assoc_field name fields in
  match float_of_yojson value with
  | Ok value -> Ok value
  | Error err -> Error (name ^ ": " ^ err)
;;

let int_field name fields =
  let* value = assoc_field name fields in
  match int_of_yojson value with
  | Ok value -> Ok value
  | Error err -> Error (name ^ ": " ^ err)
;;

let validate_interval interval_sec =
  if interval_sec <= 0 then Error "recurrence.interval_sec must be positive"
  else Ok interval_sec
;;

(* Daily recurrence intentionally uses fixed offsets only. This keeps dispatch
   deterministic across host timezone changes and avoids pretending to support
   DST-aware IANA zone rules. *)
let timezone_offset_seconds timezone =
  let parse_fixed_offset raw =
    let len = String.length raw in
    if len <> 6 || raw.[3] <> ':' then
      None
    else (
      let sign =
        match raw.[0] with
        | '+' -> Some 1
        | '-' -> Some (-1)
        | _ -> None
      in
      match sign with
      | None -> None
      | Some sign ->
        let int_sub start len =
          try Some (int_of_string (String.sub raw start len)) with
          | Failure _ -> None
        in
        match int_sub 1 2, int_sub 4 2 with
        | Some hour, Some minute when hour <= 23 && minute <= 59 ->
          Some (sign * ((hour * 3600) + (minute * 60)))
        | _ -> None)
  in
  match String.trim timezone with
  | "UTC" | "Etc/UTC" | "Z" -> Some 0
  | "Asia/Seoul" | "KST" -> Some (9 * 3600)
  | raw ->
    if String.length raw > 3 && String.sub raw 0 3 = "UTC" then
      parse_fixed_offset (String.sub raw 3 (String.length raw - 3))
    else
      parse_fixed_offset raw
;;

let validate_daily ~hour ~minute ~second ~timezone =
  let* timezone = nonempty "recurrence.timezone" timezone in
  if hour < 0 || hour > 23 then Error "recurrence.hour must be in 0..23"
  else if minute < 0 || minute > 59 then
    Error "recurrence.minute must be in 0..59"
  else if second < 0 || second > 59 then
    Error "recurrence.second must be in 0..59"
  else (
    match timezone_offset_seconds timezone with
    | Some _ -> Ok (Daily { hour; minute; second; timezone })
    | None ->
      Error
        "recurrence.timezone must be UTC, Asia/Seoul, KST, or a fixed offset like +09:00; DST-aware IANA zones are not supported")
;;

type cron_field =
  { any : bool
  ; values : int list
  }

type cron_spec =
  { minute : cron_field
  ; hour : cron_field
  ; dom : cron_field
  ; month : cron_field
  ; dow : cron_field
  }

let split_char sep value =
  let rec loop acc start idx =
    if idx >= String.length value
    then List.rev (String.sub value start (idx - start) :: acc)
    else if Char.equal value.[idx] sep
    then loop (String.sub value start (idx - start) :: acc) (idx + 1) (idx + 1)
    else loop acc start (idx + 1)
  in
  loop [] 0 0
;;

let int_of_token ~field token =
  try Ok (int_of_string token) with
  | Failure _ -> Error (Printf.sprintf "recurrence.cron.%s has non-numeric token: %s" field token)
;;

let dedupe_sorted values =
  values
  |> List.sort_uniq Int.compare
;;

let range_values ~field ~min_v ~max_v ~map_value start stop step =
  if step <= 0
  then Error (Printf.sprintf "recurrence.cron.%s step must be positive" field)
  else if start > stop
  then Error (Printf.sprintf "recurrence.cron.%s range start must be <= end" field)
  else if start < min_v || stop > max_v
  then
    Error
      (Printf.sprintf
         "recurrence.cron.%s value must be in %d..%d"
         field
         min_v
         max_v)
  else (
    let rec loop acc value =
      if value > stop
      then Ok (List.rev acc)
      else
        let* mapped = map_value value in
        loop (mapped :: acc) (value + step)
    in
    loop [] start)
;;

let parse_cron_atom ~field ~min_v ~max_v ~map_value atom =
  let atom = String.trim atom in
  if String.equal atom ""
  then Error (Printf.sprintf "recurrence.cron.%s contains an empty token" field)
  else (
    let base, step =
      match split_char '/' atom with
      | [ base ] -> base, 1
      | [ base; step_s ] ->
        (match int_of_token ~field step_s with
         | Ok step -> base, step
         | Error _ -> base, -1)
      | _ -> atom, -1
    in
    if step <= 0
    then Error (Printf.sprintf "recurrence.cron.%s step must be positive" field)
    else if String.equal base "*"
    then range_values ~field ~min_v ~max_v ~map_value min_v max_v step
    else (
      match split_char '-' base with
      | [ one ] ->
        let* value = int_of_token ~field one in
        range_values ~field ~min_v ~max_v ~map_value value value step
      | [ start_s; stop_s ] ->
        let* start = int_of_token ~field start_s in
        let* stop = int_of_token ~field stop_s in
        range_values ~field ~min_v ~max_v ~map_value start stop step
      | _ ->
        Error
          (Printf.sprintf
             "recurrence.cron.%s token must be *, n, n-m, */s, or n-m/s: %s"
             field
             atom)))
;;

let parse_cron_field ~field ~min_v ~max_v ?(map_value = fun value -> Ok value) raw =
  let raw = String.trim raw in
  if String.equal raw ""
  then Error (Printf.sprintf "recurrence.cron.%s must be non-empty" field)
  else (
    let atoms = split_char ',' raw in
    let rec loop acc = function
      | [] -> Ok { any = String.equal raw "*"; values = dedupe_sorted acc }
      | atom :: rest ->
        let* values = parse_cron_atom ~field ~min_v ~max_v ~map_value atom in
        loop (List.rev_append values acc) rest
    in
    loop [] atoms)
;;

let parse_cron_expression expression =
  let fields =
    expression
    |> String.trim
    |> String.split_on_char ' '
    |> List.filter (fun part -> not (String.equal part ""))
  in
  match fields with
  | [ minute_s; hour_s; dom_s; month_s; dow_s ] ->
    let dow_map value =
      match value with
      | 7 -> Ok 0
      | value -> Ok value
    in
    let* minute = parse_cron_field ~field:"minute" ~min_v:0 ~max_v:59 minute_s in
    let* hour = parse_cron_field ~field:"hour" ~min_v:0 ~max_v:23 hour_s in
    let* dom = parse_cron_field ~field:"day_of_month" ~min_v:1 ~max_v:31 dom_s in
    let* month = parse_cron_field ~field:"month" ~min_v:1 ~max_v:12 month_s in
    let* dow = parse_cron_field ~field:"day_of_week" ~min_v:0 ~max_v:7 ~map_value:dow_map dow_s in
    Ok { minute; hour; dom; month; dow }
  | _ ->
    Error
      "recurrence.cron.expression must be a 5-field cron expression: minute hour day-of-month month day-of-week"
;;

let max_possible_day_of_month = function
  | 2 -> Some 29
  | 4 | 6 | 9 | 11 -> Some 30
  | 1 | 3 | 5 | 7 | 8 | 10 | 12 -> Some 31
  | _ -> None
;;

let cron_has_possible_date spec =
  (* Vixie cron uses OR when both DOM and DOW are restricted. A restricted DOW
     therefore always supplies future dates. When DOW is unrestricted, at
     least one selected month must admit one selected DOM; February 29 is
     possible because Gregorian leap years recur. The parser guarantees every
     field is non-empty, so this invariant makes calendar-day search total. *)
  (not spec.dow.any)
  || List.exists
       (fun month ->
          match max_possible_day_of_month month with
          | None -> false
          | Some max_day -> List.exists (fun day -> day <= max_day) spec.dom.values)
       spec.month.values
;;

let validate_cron ~expression ~timezone =
  let* expression = nonempty "recurrence.cron.expression" expression in
  let* timezone = nonempty "recurrence.timezone" timezone in
  match timezone_offset_seconds timezone with
  | None ->
    Error
      "recurrence.timezone must be UTC, Asia/Seoul, KST, or a fixed offset like +09:00; DST-aware IANA zones are not supported"
  | Some _ ->
    let* spec = parse_cron_expression expression in
    if cron_has_possible_date spec
    then Ok (Cron { expression; timezone })
    else Error "recurrence.cron has no possible calendar date"
;;

let validate_recurrence = function
  | One_shot -> Ok One_shot
  | Interval { interval_sec } ->
    let* interval_sec = validate_interval interval_sec in
    Ok (Interval { interval_sec })
  | Daily { hour; minute; second; timezone } ->
    validate_daily ~hour ~minute ~second ~timezone
  | Cron { expression; timezone } -> validate_cron ~expression ~timezone
;;

let recurrence_evaluation_error_to_string = function
  | Invalid_persisted_recurrence detail ->
    "invalid persisted recurrence: " ^ detail
  | Unsupported_timezone timezone ->
    "unsupported recurrence timezone: " ^ timezone
  | Engine_failure detail -> "recurrence engine failure: " ^ detail
;;

let recurrence_to_yojson = function
  | One_shot -> `Assoc [ "kind", `String "one_shot" ]
  | Interval { interval_sec } ->
    `Assoc [ "kind", `String "interval"; "interval_sec", `Int interval_sec ]
  | Daily { hour; minute; second; timezone } ->
    `Assoc
      [ "kind", `String "daily"
      ; "hour", `Int hour
      ; "minute", `Int minute
      ; "second", `Int second
      ; "timezone", `String timezone
      ]
  | Cron { expression; timezone } ->
    `Assoc
      [ "kind", `String "cron"
      ; "expression", `String expression
      ; "timezone", `String timezone
      ]
;;

let recurrence_of_yojson = function
  | `Assoc fields ->
    let* kind = string_field "kind" fields in
    (match kind with
     | "one_shot" -> Ok One_shot
     | "interval" ->
       let* interval_sec = int_field "interval_sec" fields in
       Ok (Interval { interval_sec })
     | "daily" ->
       let* hour = int_field "hour" fields in
       let* minute = int_field "minute" fields in
       let* second =
         match List.assoc_opt "second" fields with
         | None -> Ok 0
         | Some value ->
           (match int_of_yojson value with
            | Ok value -> Ok value
            | Error err -> Error ("second: " ^ err))
       in
       let* timezone = string_field "timezone" fields in
       Ok (Daily { hour; minute; second; timezone })
     | "cron" ->
       let* expression = string_field "expression" fields in
       let* timezone = string_field "timezone" fields in
       Ok (Cron { expression; timezone })
     | other -> Error ("unknown recurrence kind: " ^ other))
  | _ -> Error "expected recurrence object"
;;

let actor_to_yojson (actor : actor) =
  `Assoc
    [ "id", `String actor.id
    ; "kind", `String (actor_kind_to_string actor.kind)
    ; "display_name", option_to_yojson (fun value -> `String value) actor.display_name
    ]
;;

let actor_of_yojson = function
  | `Assoc fields ->
    let* id = string_field "id" fields in
    let* kind_name = string_field "kind" fields in
    let* kind = actor_kind_of_string kind_name in
    let* display_name =
      match List.assoc_opt "display_name" fields with
      | None -> Ok None
      | Some value -> string_option_of_yojson value
    in
    Ok { id; kind; display_name }
  | _ -> Error "expected actor object"
;;

let payload_to_yojson payload =
  `Assoc
    [ "kind", `String payload.kind
    ; "schema_version", `Int payload.schema_version
    ; "body", payload.body
    ]
;;

let payload_of_yojson = function
  | `Assoc fields ->
    let* kind = string_field "kind" fields in
    let* kind = nonempty "payload.kind" kind in
    let* schema_version = int_field "schema_version" fields in
    if schema_version <= 0 then Error "payload.schema_version must be positive"
    else (
      let* body = assoc_field "body" fields in
      match body with
      | `Assoc _ -> Ok { kind; schema_version; body }
      | _ -> Error "payload.body must be a JSON object")
  | _ -> Error "payload must be a JSON object"
;;

let payload_digest payload = payload |> payload_to_yojson |> sha256_json

let seconds_per_day = 86400.0

let next_periodic_due_after ~period ~now ~anchor =
  if period <= 0.0 then
    Error
      (Invalid_persisted_recurrence
         "recurrence.interval_sec must be positive")
  else if anchor > now then
    Ok (Next_due_at anchor)
  else
    let missed = floor ((now -. anchor) /. period) +. 1.0 in
    Ok (Next_due_at (anchor +. (missed *. period)))
;;

let next_daily_due_after ~hour ~minute ~second ~timezone ~now =
  if hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59
  then
    Error
      (Invalid_persisted_recurrence
         "daily hour, minute, or second is outside its valid range")
  else
    match timezone_offset_seconds timezone with
    | None -> Error (Unsupported_timezone timezone)
    | Some offset ->
      let local_now = now +. float_of_int offset in
      let day_start = floor (local_now /. seconds_per_day) *. seconds_per_day in
      let target_second =
        float_of_int ((hour * 3600) + (minute * 60) + second)
      in
      let target_utc = day_start +. target_second -. float_of_int offset in
      if target_utc > now
      then Ok (Next_due_at target_utc)
      else Ok (Next_due_at (target_utc +. seconds_per_day))
;;

let field_matches field value = List.mem value field.values

let cron_day_matches spec tm =
  let dom_matches = field_matches spec.dom tm.Unix.tm_mday in
  let dow_matches = field_matches spec.dow tm.Unix.tm_wday in
  match spec.dom.any, spec.dow.any with
  | true, true -> true
  | true, false -> dow_matches
  | false, true -> dom_matches
  | false, false -> dom_matches || dow_matches
;;

let cron_date_matches spec tm =
  field_matches spec.month (tm.Unix.tm_mon + 1) && cron_day_matches spec tm
;;

let cron_slots spec =
  List.concat_map
    (fun hour -> List.map (fun minute -> (hour * 60) + minute) spec.minute.values)
    spec.hour.values
;;

let next_cron_due_after ~expression ~timezone ~now =
  match parse_cron_expression expression, timezone_offset_seconds timezone with
  | Error detail, _ -> Error (Invalid_persisted_recurrence detail)
  | _, None -> Error (Unsupported_timezone timezone)
  | Ok spec, Some offset ->
    if not (cron_has_possible_date spec) then
      Error
        (Invalid_persisted_recurrence
           "recurrence.cron has no possible calendar date")
    else if not (Float.is_finite now) then
      Error (Engine_failure "recurrence reference time is not finite")
    else
      (try
         let offset = float_of_int offset in
         let first_local = (floor (now /. 60.0) *. 60.0) +. 60.0 +. offset in
         let first_day = floor (first_local /. seconds_per_day) *. seconds_per_day in
         let first_slot = int_of_float ((first_local -. first_day) /. 60.0) in
         let slots = cron_slots spec in
         (* [cron_has_possible_date] plus non-empty parsed hour/minute fields
            proves that some future day and slot exists. Advancing one calendar
            day is therefore total and needs no search horizon. *)
         let rec loop local_day not_before_slot =
           let tm = Unix.gmtime local_day in
           let slot =
             if cron_date_matches spec tm
             then List.find_opt (fun slot -> slot >= not_before_slot) slots
             else None
           in
           match slot with
           | Some slot ->
             let candidate = local_day +. float_of_int (slot * 60) -. offset in
             if candidate > now
             then Ok (Next_due_at candidate)
             else Error (Engine_failure "cron engine produced a non-future occurrence")
           | None ->
             let next_day = local_day +. seconds_per_day in
             if Float.is_finite next_day && next_day > local_day
             then loop next_day 0
             else Error (Engine_failure "cron calendar day overflow")
         in
         loop first_day first_slot
       with
       | Invalid_argument detail | Failure detail -> Error (Engine_failure detail)
       | Unix.Unix_error (error, function_name, argument) ->
         Error
           (Engine_failure
              (Printf.sprintf
                 "%s(%s): %s"
                 function_name
                 argument
                 (Unix.error_message error))))
;;

let first_due_after ~now = function
  | One_shot | Interval _ -> Ok No_next
  | Daily { hour; minute; second; timezone } ->
    next_daily_due_after ~hour ~minute ~second ~timezone ~now
  | Cron { expression; timezone } -> next_cron_due_after ~expression ~timezone ~now
;;

let next_due_after ~now (request : schedule_request) =
  match request.recurrence with
  | One_shot -> Ok No_next
  | Interval { interval_sec } ->
    next_periodic_due_after
      ~period:(float_of_int interval_sec)
      ~now
      ~anchor:request.due_at
  | Daily { hour; minute; second; timezone } ->
    next_daily_due_after ~hour ~minute ~second ~timezone ~now
  | Cron { expression; timezone } -> next_cron_due_after ~expression ~timezone ~now
;;

let reschedule_after_due_signal ~now (request : schedule_request) =
  match request.status with
  | Due ->
    (match next_due_after ~now request with
     | Error _ as error -> error
     | Ok No_next -> Ok None
     | Ok (Next_due_at due_at) -> Ok (Some { request with status = Scheduled; due_at }))
  | Scheduled | Running | Succeeded | Failed | Cancelled | Expired ->
    Ok None
;;

let execution_record_to_yojson (execution : execution_record) =
  `Assoc
    [ "execution_id", `String execution.execution_id
    ; "schedule_id", `String execution.schedule_id
    ; "started_at", float_to_yojson execution.started_at
    ; "finished_at", option_to_yojson float_to_yojson execution.finished_at
    ; "due_at", float_to_yojson execution.due_at
    ; "payload_digest", `String execution.payload_digest
    ; "status", `String (execution_status_to_string execution.status)
    ; "detail", option_to_yojson (fun value -> value) execution.detail
    ; "error", option_to_yojson (fun value -> `String value) execution.error
    ]
;;

let execution_record_of_yojson = function
  | `Assoc fields ->
    let* execution_id = string_field "execution_id" fields in
    let* schedule_id = string_field "schedule_id" fields in
    let* started_at = float_field "started_at" fields in
    let* finished_at =
      match List.assoc_opt "finished_at" fields with
      | None | Some `Null -> Ok None
      | Some value ->
        let* value = float_of_yojson value in
        Ok (Some value)
    in
    let* due_at = float_field "due_at" fields in
    let* payload_digest = string_field "payload_digest" fields in
    let* status_name = string_field "status" fields in
    let* status = execution_status_of_string status_name in
    let detail =
      match List.assoc_opt "detail" fields with
      | None | Some `Null -> None
      | Some value -> Some value
    in
    let* error =
      match List.assoc_opt "error" fields with
      | None -> Ok None
      | Some value -> string_option_of_yojson value
    in
    Ok
      { execution_id
      ; schedule_id
      ; started_at
      ; finished_at
      ; due_at
      ; payload_digest
      ; status
      ; detail
      ; error
      }
  | _ -> Error "expected execution_record object"
;;

let schedule_request_to_yojson (request : schedule_request) =
  `Assoc
    [ "schedule_id", `String request.schedule_id
    ; "requested_by", actor_to_yojson request.requested_by
    ; "scheduled_by", actor_to_yojson request.scheduled_by
    ; "requested_at", float_to_yojson request.requested_at
    ; "due_at", float_to_yojson request.due_at
    ; "expires_at", option_to_yojson float_to_yojson request.expires_at
    ; "payload", payload_to_yojson request.payload
    ; "status", `String (schedule_status_to_string request.status)
    ; "source", `String (schedule_source_to_string request.source)
    ; "recurrence", recurrence_to_yojson request.recurrence
    ]
;;

let schedule_request_of_yojson = function
  | `Assoc fields ->
    let* schedule_id = string_field "schedule_id" fields in
    let* requested_by_json = assoc_field "requested_by" fields in
    let* requested_by = actor_of_yojson requested_by_json in
    let* scheduled_by_json = assoc_field "scheduled_by" fields in
    let* scheduled_by = actor_of_yojson scheduled_by_json in
    let* requested_at = float_field "requested_at" fields in
    let* due_at = float_field "due_at" fields in
    let* expires_at =
      match List.assoc_opt "expires_at" fields with
      | None | Some `Null -> Ok None
      | Some value ->
        let* value = float_of_yojson value in
        Ok (Some value)
    in
    let* payload_json = assoc_field "payload" fields in
    let* payload = payload_of_yojson payload_json in
    let* status_name = string_field "status" fields in
    let* status = schedule_status_of_string status_name in
    let* source_name = string_field "source" fields in
    let* source = schedule_source_of_string source_name in
    let* recurrence =
      match List.assoc_opt "recurrence" fields with
      | None -> Ok One_shot
      | Some value -> recurrence_of_yojson value
    in
    Ok
      { schedule_id
      ; requested_by
      ; scheduled_by
      ; requested_at
      ; due_at
      ; expires_at
      ; payload
      ; status
      ; source
      ; recurrence
      }
  | _ -> Error "expected schedule_request object"
;;

let create_request
  ~schedule_id
  ~requested_by
  ~scheduled_by
  ~requested_at
  ~due_at
  ?expires_at
  ~payload
  ~source
  ?(recurrence = One_shot)
  ()
  =
  let* schedule_id = nonempty "schedule_id" schedule_id in
  let* _ = nonempty "requested_by.id" requested_by.id in
  let* _ = nonempty "scheduled_by.id" scheduled_by.id in
  let* payload = payload_of_yojson payload in
  let* recurrence = validate_recurrence recurrence in
  Ok
    { schedule_id
    ; requested_by
    ; scheduled_by
    ; requested_at
    ; due_at
    ; expires_at
    ; payload
    ; status = Scheduled
    ; source
    ; recurrence
    }
;;

let expired_at ~now (request : schedule_request) =
  match request.expires_at with
  | Some expires_at when expires_at <= now -> true
  | None | Some _ -> false
;;

let mark_due ~now (request : schedule_request) =
  match request.status with
  | Scheduled | Due when expired_at ~now request ->
    { request with status = Expired }
  | Scheduled when request.due_at <= now -> { request with status = Due }
  | _ -> request
;;
