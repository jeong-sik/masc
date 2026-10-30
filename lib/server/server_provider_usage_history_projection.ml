module Usage = Runtime_provider_usage_window

open Result.Syntax

let kind_json = function
  | Usage.Five_hour -> `String "five_hour"
  | Usage.Seven_day -> `String "seven_day"
  | Usage.Duration_minutes minutes ->
      `String (Printf.sprintf "duration_%dm" minutes)
  | Usage.Provider_label label -> `String ("provider:" ^ label)

let utilization_json = function
  | Usage.Fraction value -> [ "unit", `String "fraction"; "value", `Float value ]
  | Usage.Percent value -> [ "unit", `String "percent"; "value", `Int value ]
  | Usage.Usd { used; limit } ->
      [ "unit", `String "usd"; "value", `Float used
      ; "limit", Json_util.float_opt_to_json limit ]

let record_json ~scope_id ~observed_at (report : Usage.report) =
  let source = Usage.source_to_string report.source in
  let snapshot = match Usage.report_shape report.source with
    | Sparse_update -> []
    | Complete_snapshot ->
        [ `Assoc [ "record", `String "complete_snapshot";
            "scope_id", `String scope_id; "source", `String source;
            "state", `String (if report.windows = [] then "reported_no_windows" else "reported");
            "observed_at", `Float observed_at ] ] in
  snapshot @ List.map
    (fun (window : Usage.window) ->
      `Assoc
        ([ "scope_id", `String scope_id
        ; "source", `String source
        ; "kind", kind_json window.kind
        ; "limit_id", Option.fold ~none:`Null ~some:(fun id -> `String id) window.limit_id
        ; "observed_at", `Float observed_at
        ; "resets_at", Option.fold ~none:`Null ~some:(fun ts -> `Int ts) window.resets_at
        ] @ utilization_json window.utilization))
    report.windows

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
  | Some (`String "usd"), _ ->
      let* used = number "value" json in
      let* limit = match member "limit" json with
        | Some `Null -> Ok None
        | Some _ -> let* limit = number "limit" json in
            if limit > 0.0 then Ok (Some limit)
            else Error "provider usage history: invalid USD limit"
        | None -> Error "provider usage history: missing USD limit"
      in
      if used >= 0.0 then Ok (Usage.Usd { used; limit })
      else Error "provider usage history: invalid USD usage"
  | _ -> Error "provider usage history: invalid unit or value"

let decode_point json =
  let* scope_id = string "scope_id" json in
  let* source = string "source" json in
  let* kind = string "kind" json in
  (* OpenRouter renamed the display label; retain the same history series.
     Restrict the alias to its source so another provider's label is untouched. *)
  let kind =
    if String.equal source (Usage.source_to_string Usage.Openrouter_key_read) then
      match kind with
      | "provider:credit limit" -> "provider:API key credit limit"
      | "provider:credit usage (all time)" -> "provider:API key usage (all time)"
      | _ -> kind
    else kind
  in
  let* limit_id = optional_string "limit_id" json in
  let* utilization = utilization_of_json json in
  let* observed_at = number "observed_at" json in
  let* resets_at = optional_int "resets_at" json in
  Ok { scope_id; source; kind; limit_id; utilization; observed_at; resets_at }

let point_json point =
  `Assoc
    ([ "scope_id", `String point.scope_id
    ; "source", `String point.source
    ; "kind", `String point.kind
    ; "limit_id", Option.fold ~none:`Null ~some:(fun id -> `String id) point.limit_id
    ; "observed_at", `Float point.observed_at
    ; "resets_at", Option.fold ~none:`Null ~some:(fun ts -> `Int ts) point.resets_at
    ] @ utilization_json point.utilization)

type snapshot_state = Reported | Reported_no_windows

type snapshot = { observed_at : float; state : snapshot_state }

type item =
  | Point of point
  | Complete_snapshot of {
      scope_id : string;
      source : string;
      observed_at : float;
      state : snapshot_state;
    }

let decode_item json =
  match member "record" json with
  | Some (`String "complete_snapshot") ->
      let* scope_id = string "scope_id" json in
      let* source = string "source" json in
      let* observed_at = number "observed_at" json in
      let* state =
        match member "state" json with
        | Some (`String "reported_no_windows") -> Ok Reported_no_windows
        | Some (`String "reported") | None -> Ok Reported
        | Some _ -> Error "provider usage history: invalid snapshot state"
      in
      Ok (Complete_snapshot { scope_id; source; observed_at; state })
  | Some _ -> Error "provider usage history: unknown record kind"
  | None -> let* point = decode_point json in Ok (Point point)

module Source_day = struct
  type t = { scope_id : string; source : string; day : string }

  let compare a b =
    compare (a.scope_id, a.source, a.day) (b.scope_id, b.source, b.day)
end

module Window_key = struct
  type t = string * string option

  let compare = compare
end

module Scope_day = struct
  type t = { scope_id : string; day : string }

  let compare a b = compare (a.scope_id, a.day) (b.scope_id, b.day)
end

module Display_day = struct
  type t = Scope_day.t * Window_key.t

  let compare (day_a, window_a) (day_b, window_b) =
    match Scope_day.compare day_a day_b with
    | 0 -> Window_key.compare window_a window_b
    | order -> order
end

module Source_day_map = Map.Make (Source_day)
module Window_map = Map.Make (Window_key)
module Display_day_map = Map.Make (Display_day)
module Scope_day_map = Map.Make (Scope_day)
module Scope_day_set = Set.Make (Scope_day)

type source_day = {
  snapshot : snapshot option;
  windows : point Window_map.t;
}

type t = {
  since_at : float;
  now : float;
  sources : source_day Source_day_map.t;
  unreadable_reports : int;
}

let create ~since_at ~now =
  { since_at; now; sources = Source_day_map.empty; unreadable_reports = 0 }

let update_source_day t key update =
  let previous =
    match Source_day_map.find_opt key t.sources with
    | Some held -> held
    | None -> { snapshot = None; windows = Window_map.empty }
  in
  { t with sources = Source_day_map.add key (update previous) t.sources }

let in_window t observed_at = observed_at >= t.since_at && observed_at <= t.now

let consume_item t json =
  let* item = decode_item json in
  let next =
    match item with
    | Point point ->
        if not (in_window t point.observed_at) then t
        else
          let day = Log.format_utc_date_of point.observed_at in
          let key = { Source_day.scope_id = point.scope_id; source = point.source; day } in
          update_source_day t key (fun held ->
            let window_key = point.kind, point.limit_id in
            match Window_map.find_opt window_key held.windows with
            | Some previous when previous.observed_at >= point.observed_at -> held
            | Some _ | None ->
                { held with windows = Window_map.add window_key point held.windows })
    | Complete_snapshot { scope_id; source; observed_at; state } ->
        if not (in_window t observed_at) then t
        else
          let day = Log.format_utc_date_of observed_at in
          let key = { Source_day.scope_id; source; day } in
          update_source_day t key (fun held ->
            match held.snapshot with
            | Some previous when previous.observed_at >= observed_at -> held
            | Some _ | None ->
                { held with snapshot = Some { observed_at; state } })
  in
  Ok next

let note_unreadable t = { t with unreadable_reports = t.unreadable_reports + 1 }

let daily_points t =
  (* Retain source rows until this fold: a delayed append must still be judged
     against the latest complete snapshot from its own observation day. *)
  Source_day_map.fold
    (fun (source_day : Source_day.t) held daily ->
      Window_map.fold
        (fun window_key (point : point) daily ->
          match held.snapshot with
          | Some snapshot when point.observed_at < snapshot.observed_at -> daily
          | Some _ | None ->
              (* Replace source windows before selecting a display winner, so
                 an empty source does not erase another source's reading. *)
              let day = { Scope_day.scope_id = source_day.scope_id; day = source_day.day } in
              let key = day, window_key in
              match Display_day_map.find_opt key daily with
              | Some (previous : point) when compare (previous.observed_at, previous.source)
                  (point.observed_at, point.source) >= 0 -> daily
              | Some _ | None -> Display_day_map.add key point daily)
        held.windows daily)
    t.sources Display_day_map.empty

let empty_reports t daily =
  let reported_days =
    Display_day_map.fold
      (fun (day, _) _ days -> Scope_day_set.add day days)
      daily Scope_day_set.empty
  in
  let empty_days =
    Source_day_map.fold
      (fun (source_day : Source_day.t) held empty_days ->
        match held.snapshot with
        | None | Some { state = Reported; _ } -> empty_days
        | Some { observed_at; state = Reported_no_windows } ->
            let day = { Scope_day.scope_id = source_day.scope_id; day = source_day.day } in
            if Scope_day_set.mem day reported_days then empty_days
            else
              match Scope_day_map.find_opt day empty_days with
              | Some previous when previous >= observed_at -> empty_days
              | Some _ | None -> Scope_day_map.add day observed_at empty_days)
      t.sources Scope_day_map.empty
  in
  Scope_day_map.fold
    (fun (day : Scope_day.t) observed_at rows -> (day.scope_id, observed_at) :: rows)
    empty_days []
  |> List.sort compare
  |> List.map (fun (scope_id, observed_at) ->
      `Assoc [ "scope_id", `String scope_id; "observed_at", `Float observed_at ])

let response_json ~days t =
  let daily = daily_points t in
  let points =
    Display_day_map.fold (fun _ point points -> point :: points) daily []
    |> List.sort (fun (a : point) (b : point) ->
        compare (a.scope_id, a.kind, a.limit_id, a.observed_at)
          (b.scope_id, b.kind, b.limit_id, b.observed_at))
  in
  `Assoc
    [ "days", `Int days
    ; "generated_at", `Float t.now
    ; "sampling", `String "latest_provider_report_per_utc_day"
    ; "unreadable_reports", `Int t.unreadable_reports
    ; "reported_no_windows", `List (empty_reports t daily)
    ; "points", `List (List.map point_json points)
    ]
