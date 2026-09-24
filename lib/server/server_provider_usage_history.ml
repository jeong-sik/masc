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

type point = {
  scope_id : string;
  source : string;
  kind : string;
  limit_id : string option;
  unit : string;
  value : Yojson.Safe.t;
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

let decode json =
  let* scope_id = string "scope_id" json in
  let* source = string "source" json in
  let* kind = string "kind" json in
  let* limit_id = optional_string "limit_id" json in
  let* unit = string "unit" json in
  let* value =
    match member "value" json with
    | Some (`Float value) when Float.is_finite value -> Ok (`Float value)
    | Some (`Int value) -> Ok (`Int value)
    | _ -> Error "provider usage history: invalid value"
  in
  let* observed_at = number "observed_at" json in
  let* resets_at = optional_int "resets_at" json in
  if unit <> "fraction" && unit <> "percent" then
    Error "provider usage history: unknown unit"
  else Ok { scope_id; source; kind; limit_id; unit; value; observed_at; resets_at }

let point_json point =
  `Assoc
    [ "scope_id", `String point.scope_id
    ; "source", `String point.source
    ; "kind", `String point.kind
    ; "limit_id", Option.fold ~none:`Null ~some:(fun id -> `String id) point.limit_id
    ; "unit", `String point.unit
    ; "value", point.value
    ; "observed_at", `Float point.observed_at
    ; "resets_at", Option.fold ~none:`Null ~some:(fun ts -> `Int ts) point.resets_at
    ]

let window_start ~now ~days =
  (floor (now /. 86400.0) -. float_of_int (days - 1)) *. 86400.0

let failure_in_window ~now ~days =
  match Usage.record_observer_failure_at () with
  | Some at -> at >= window_start ~now ~days && at <= now
  | None -> false

let read config ~now ~days =
  if not (List.mem days [ 1; 7; 14 ]) then
    Error "provider usage history: days must be 1, 7, or 14"
  else if failure_in_window ~now ~days then
    Error "provider usage history incomplete: a report could not be stored"
  else
    let since_at = window_start ~now ~days in
    let journal = store config in
    let latest = Hashtbl.create 128 in
    let error = ref None in
    let consume = function
      | Dated_jsonl.Malformed_json { detail; _ } ->
          error := Some ("provider usage history: malformed JSON: " ^ detail)
      | Dated_jsonl.Parsed json ->
          let items =
            match json with
            | `List items -> items
            | _ ->
                error := Some "provider usage history: expected report list";
                []
          in
          List.iter
            (fun item ->
              match decode item with
              | Error detail -> error := Some detail
              | Ok point when point.observed_at >= since_at && point.observed_at <= now ->
                  let day = Log.format_utc_date_of point.observed_at in
                  let key = point.scope_id, point.kind, point.limit_id, day in
                  (match Hashtbl.find_opt latest key with
                   | Some held when held.observed_at >= point.observed_at -> ()
                   | Some _ | None -> Hashtbl.replace latest key point)
              | Ok _ -> ())
            items
    in
    let result =
      Dated_jsonl.iter_range_entries_result journal
        ~since:(Log.format_utc_date_of since_at)
        ~until:(Log.format_utc_date_of now) consume
    in
    match result, !error with
    | Error read_error, _ ->
        Log.Server.warn "provider usage history read failed: %s"
          (Dated_jsonl.read_error_to_string read_error);
        Error "provider usage history store unavailable"
    | Ok (), Some detail -> Error detail
    | Ok (), None ->
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
            [ "days", `Int days
            ; "generated_at", `Float now
            ; "sampling", `String "latest_provider_report_per_utc_day"
            ; "points", `List (List.map point_json points)
            ])
