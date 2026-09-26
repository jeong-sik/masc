module Usage = Runtime_provider_usage_window

let ( let* ) = Result.bind

let store config =
  let base_dir =
    Filename.concat (Workspace_utils.masc_dir config) "provider_usage_history"
  in
  Dated_jsonl.create ~base_dir ~retention_days:16 ()

let scope_id scope =
  Digest.to_hex (Digest.string (Runtime_quota_window.scope_to_string scope))

let kind_json = function
  | Usage.Five_hour -> `String "five_hour"
  | Usage.Seven_day -> `String "seven_day"
  | Usage.Duration_minutes minutes ->
      `String (Printf.sprintf "duration_%dm" minutes)
  | Usage.Provider_label label -> `String ("provider:" ^ label)

let utilization_json = function
  | Usage.Fraction value -> "fraction", `Float value
  | Usage.Percent value -> "percent", `Int value

let record_json ~scope ~observed_at (report : Usage.report) =
  let scope_id = scope_id scope in
  let source = Usage.source_to_string report.source in
  List.map
    (fun (window : Usage.window) ->
      let unit, value = utilization_json window.utilization in
      `Assoc
        [ "scope_id", `String scope_id
        ; "source", `String source
        ; "kind", kind_json window.kind
        ; "limit_id", Option.fold ~none:`Null ~some:(fun id -> `String id) window.limit_id
        ; "unit", `String unit
        ; "value", value
        ; "observed_at", `Float observed_at
        ; "resets_at", Option.fold ~none:`Null ~some:(fun ts -> `Int ts) window.resets_at
        ])
    report.windows

let install config =
  let journal = store config in
  Usage.set_record_observer (fun ~scope ~observed_at report ->
    Dated_jsonl.append journal
      (`List (record_json ~scope ~observed_at report)))

type window = One_day | Seven_days | Fourteen_days

let window_of_days = function
  | 1 -> Some One_day
  | 7 -> Some Seven_days
  | 14 -> Some Fourteen_days
  | _ -> None

let days_of_window = function
  | One_day -> 1
  | Seven_days -> 7
  | Fourteen_days -> 14

type point = {
  scope_id : string;
  source : string;
  kind : string;
  limit_id : string option;
  utilization : Usage.utilization;
  observed_at : float;
  resets_at : int option;
}

let member key json = Json_util.assoc_member_opt key json

let string key json =
  match member key json with
  | Some (`String value) when value <> "" -> Ok value
  | _ -> Error ("provider usage history: missing " ^ key)

let optional_string key json =
  match member key json with
  | Some (`String value) -> Ok (Some value)
  | Some `Null -> Ok None
  | _ -> Error ("provider usage history: invalid " ^ key)

let optional_int key json =
  match member key json with
  | Some (`Int value) -> Ok (Some value)
  | Some `Null -> Ok None
  | _ -> Error ("provider usage history: invalid " ^ key)

let number key json =
  match member key json with
  | Some (`Float value) when Float.is_finite value -> Ok value
  | Some (`Int value) -> Ok (float_of_int value)
  | _ -> Error ("provider usage history: invalid " ^ key)

(* The stored line back into the variant [utilization_json] wrote: the unit
   word and the value's JSON type decide together, and anything else is not
   a report this store wrote. *)
let utilization_of_json json =
  match member "unit" json, member "value" json with
  | Some (`String "fraction"), Some (`Float value) when Float.is_finite value ->
      Ok (Usage.Fraction value)
  | Some (`String "fraction"), Some (`Int value) ->
      Ok (Usage.Fraction (float_of_int value))
  | Some (`String "percent"), Some (`Int value) -> Ok (Usage.Percent value)
  | _ -> Error "provider usage history: invalid unit or value"

let decode json =
  let* scope_id = string "scope_id" json in
  let* source = string "source" json in
  let* kind = string "kind" json in
  let* limit_id = optional_string "limit_id" json in
  let* utilization = utilization_of_json json in
  let* observed_at = number "observed_at" json in
  let* resets_at = optional_int "resets_at" json in
  Ok { scope_id; source; kind; limit_id; utilization; observed_at; resets_at }

let point_json point =
  let unit, value = utilization_json point.utilization in
  `Assoc
    [ "scope_id", `String point.scope_id
    ; "source", `String point.source
    ; "kind", `String point.kind
    ; "limit_id", Option.fold ~none:`Null ~some:(fun id -> `String id) point.limit_id
    ; "unit", `String unit
    ; "value", value
    ; "observed_at", `Float point.observed_at
    ; "resets_at", Option.fold ~none:`Null ~some:(fun ts -> `Int ts) point.resets_at
    ]

let window_start ~now ~window =
  (floor (now /. 86400.0) -. float_of_int (days_of_window window - 1)) *. 86400.0

let failure_in_window ~now ~window =
  match Usage.record_observer_failure_at () with
  | Some at -> at >= window_start ~now ~window && at <= now
  | None -> false

(* A stored line that cannot be read is logged with its place and counted in
   the answer, and the rest of the window is still read: one bad line is one
   unknown report, not fourteen unknown days. The count is the evidence that
   something is missing, so the reader never takes a gap for a quiet day. *)
let read config ~now ~window =
  if failure_in_window ~now ~window then
    Error "provider usage history incomplete: a report could not be stored"
  else
    let since_at = window_start ~now ~window in
    let journal = store config in
    let latest = Hashtbl.create 128 in
    let unreadable = ref 0 in
    let skip ~where detail =
      Log.Server.warn "provider usage history unreadable report: %s: %s" where
        detail;
      incr unreadable
    in
    let consume = function
      | Dated_jsonl.Malformed_json { path; line_number; detail } ->
          skip
            ~where:
              (Printf.sprintf "%s:%s" path
                 (Option.fold ~none:"?" ~some:string_of_int line_number))
            detail
      | Dated_jsonl.Parsed (`List items) ->
          List.iter
            (fun item ->
              match decode item with
              | Error detail -> skip ~where:"stored report" detail
              | Ok point when point.observed_at >= since_at && point.observed_at <= now ->
                  let day = Log.format_utc_date_of point.observed_at in
                  let key = point.scope_id, point.kind, point.limit_id, day in
                  (match Hashtbl.find_opt latest key with
                   | Some held when held.observed_at >= point.observed_at -> ()
                   | Some _ | None -> Hashtbl.replace latest key point)
              | Ok _ -> ())
            items
      | Dated_jsonl.Parsed _ ->
          skip ~where:"stored line" "expected a report list"
    in
    let result =
      Dated_jsonl.iter_range_entries_result journal
        ~since:(Log.format_utc_date_of since_at)
        ~until:(Log.format_utc_date_of now) consume
    in
    match result with
    | Error read_error ->
        Log.Server.warn "provider usage history read failed: %s"
          (Dated_jsonl.read_error_to_string read_error);
        Error "provider usage history store unavailable"
    | Ok () ->
        let points = Hashtbl.fold (fun _ point acc -> point :: acc) latest [] in
        let points =
          List.sort
            (fun a b ->
              let key p = p.scope_id, p.kind, p.limit_id, p.observed_at in
              compare (key a) (key b))
            points
        in
        Ok
          (`Assoc
            [ "days", `Int (days_of_window window)
            ; "generated_at", `Float now
            ; "sampling", `String "latest_provider_report_per_utc_day"
            ; "unreadable_reports", `Int !unreadable
            ; "points", `List (List.map point_json points)
            ])
