module Usage = Runtime_provider_usage_window

open Result.Syntax

let provider_kind_prefix = "provider:"

let kind_json = function
  | Usage.Five_hour -> `String "five_hour"
  | Usage.Seven_day -> `String "seven_day"
  | Usage.Duration_minutes minutes ->
      `String (Printf.sprintf "duration_%dm" minutes)
  | Usage.Provider_label label -> `String (provider_kind_prefix ^ label)

(* The stored word back into the kind [kind_json] wrote it for. *)
let kind_of_stored kind =
  match kind with
  | "five_hour" -> Some Usage.Five_hour
  | "seven_day" -> Some Usage.Seven_day
  | _ ->
      (match Scanf.sscanf_opt kind "duration_%dm%!" (fun minutes -> minutes) with
       | Some minutes -> Some (Usage.Duration_minutes minutes)
       | None ->
           if String.starts_with ~prefix:provider_kind_prefix kind then
             let from = String.length provider_kind_prefix in
             Some (Usage.Provider_label (String.sub kind from (String.length kind - from)))
           else None)

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
          (* What the window limits is decided from the provider's answer,
             not from its source and kind, so a row that is to be put back
             in the table after a restart has to carry it. The daily history
             does not show it, but a row whose role is not a word this build
             writes is a row that could not be read. *)
        ; "role", `String (Usage.window_role_to_string window.role)
        ; "observed_at", `Float observed_at
        ; "resets_at", Option.fold ~none:`Null ~some:(fun ts -> `Int ts) window.resets_at
        ] @ Usage.utilization_fields window.utilization))
    report.windows

type point = {
  scope_id : string;
  source : string;
  kind : string;
  limit_id : string option;
  role : Usage.window_role option;
      (* [None] for a row stored before rows carried a role. Only the
         restart read uses it. *)
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

(* The stored line back into the variant [Usage.utilization_fields] wrote: the unit
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
  let* role =
    match member "role" json with
    | None -> Ok None
    | Some (`String word) ->
        (match Usage.window_role_of_string word with
         | Some role -> Ok (Some role)
         | None -> Error "provider usage history: unknown role")
    | Some _ -> Error "provider usage history: invalid role"
  in
  let* utilization = utilization_of_json json in
  let* observed_at = number "observed_at" json in
  let* resets_at = optional_int "resets_at" json in
  Ok { scope_id; source; kind; limit_id; role; utilization; observed_at; resets_at }

(* The report a stored item belongs to, read on its own so that an item whose
   other fields cannot be read still names its report. *)
let report_of_item json =
  Result.to_option
    (let* scope_id = string "scope_id" json in
     let* source = string "source" json in
     let* observed_at = number "observed_at" json in
     Ok (scope_id, source, observed_at))

let point_json point =
  `Assoc
    ([ "scope_id", `String point.scope_id
    ; "source", `String point.source
    ; "kind", `String point.kind
    ; "limit_id", Option.fold ~none:`Null ~some:(fun id -> `String id) point.limit_id
    ; "observed_at", `Float point.observed_at
    ; "resets_at", Option.fold ~none:`Null ~some:(fun ts -> `Int ts) point.resets_at
    ] @ Usage.utilization_fields point.utilization)

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
  unread_at : float option;
      (* When the latest report with an item that could not be read was
         observed. *)
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
    | None -> { snapshot = None; windows = Window_map.empty; unread_at = None }
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

let note_unread_report t (scope_id, source, observed_at) =
  if not (in_window t observed_at) then t
  else
    let day = Log.format_utc_date_of observed_at in
    update_source_day t { Source_day.scope_id; source; day } (fun held ->
      match held.unread_at with
      | Some previous when previous >= observed_at -> held
      | Some _ | None -> { held with unread_at = Some observed_at })

let consume_report t items =
  let t, unread =
    List.fold_left
      (fun (t, unread) item ->
        match consume_item t item with
        | Ok next -> next, unread
        | Error detail -> note_unreadable t, detail :: unread)
      (t, []) items
  in
  match unread with
  | [] -> t, []
  | _ :: _ ->
      (* The items of one line are one report, so the items that were read
         name the report of the ones that were not. *)
      let t =
        List.fold_left
          (fun t item ->
            match report_of_item item with
            | Some report -> note_unread_report t report
            | None -> t)
          t items
      in
      t, List.rev unread

let unbounded () = create ~since_at:Float.neg_infinity ~now:Float.infinity

(* [kept] holds, per source, day and window, the latest reading of the rows it
   consumed, so passing it through the rules [consume_item] applies yields
   what consuming those rows here would have: a day starts on a UTC midnight
   and so does [t]'s window, so a day's readings are all in it or all out of
   it. A reading later than [t.now] hides an earlier one of its own day until
   [t.now] passes it, which only a wall clock set back can produce. *)
let absorb t kept =
  let t = { t with unreadable_reports = t.unreadable_reports + kept.unreadable_reports } in
  Source_day_map.fold
    (fun key (held : source_day) t ->
      let t =
        match held.snapshot with
        | Some snapshot when in_window t snapshot.observed_at ->
            update_source_day t key (fun current ->
              match current.snapshot with
              | Some previous when previous.observed_at >= snapshot.observed_at -> current
              | Some _ | None -> { current with snapshot = Some snapshot })
        | Some _ | None -> t
      in
      let t =
        match held.unread_at with
        | Some observed_at -> note_unread_report t (key.scope_id, key.source, observed_at)
        | None -> t
      in
      Window_map.fold
        (fun window_key (point : point) t ->
          if not (in_window t point.observed_at) then t
          else
            update_source_day t key (fun current ->
              match Window_map.find_opt window_key current.windows with
              | Some previous when previous.observed_at >= point.observed_at -> current
              | Some _ | None ->
                  { current with windows = Window_map.add window_key point current.windows }))
        held.windows t)
    kept.sources t

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

module Scope_source = struct
  type t = string * string

  let compare = compare
end

module Scope_source_map = Map.Make (Scope_source)

type stored =
  | Report of { observed_at : float; report : Usage.report }
  | Unreadable_complete_report of { source : Usage.source; observed_at : float }

type stored_reports = {
  reports : (string * stored) list;
  unrestorable : int;
}

(* Each source's days folded into one: its latest complete snapshot and the
   latest reading of each window. *)
let latest_by_source t =
  Source_day_map.fold
    (fun (key : Source_day.t) (held : source_day) latest ->
      let key = key.scope_id, key.source in
      let merged =
        match Scope_source_map.find_opt key latest with
        | None -> held
        | Some (current : source_day) ->
            let snapshot =
              match current.snapshot, held.snapshot with
              | Some a, Some b -> Some (if a.observed_at >= b.observed_at then a else b)
              | (Some _ as only), None | None, only -> only
            in
            let windows =
              Window_map.union
                (fun _ (a : point) (b : point) ->
                  Some (if a.observed_at >= b.observed_at then a else b))
                current.windows held.windows
            in
            let unread_at =
              match current.unread_at, held.unread_at with
              | Some a, Some b -> Some (Float.max a b)
              | (Some _ as only), None | None, only -> only
            in
            { snapshot; windows; unread_at }
      in
      Scope_source_map.add key merged latest)
    t.sources Scope_source_map.empty

(* Readings that share an observation time were one report. *)
let reports_of_readings source readings =
  List.stable_sort (fun (a, _) (b, _) -> Float.compare a b) readings
  |> List.fold_left
       (fun groups (observed_at, window) ->
         match groups with
         | (held_at, windows) :: rest when Float.equal held_at observed_at ->
             (held_at, window :: windows) :: rest
         | _ -> (observed_at, [ window ]) :: groups)
       []
  |> List.rev_map (fun (observed_at, windows) ->
       observed_at, { Usage.source; windows = List.rev windows })

type reading =
  | Restorable of float * Usage.window
  | Without_role
  | Kind_not_written of float

let reading_of_point (point : point) =
  match point.role with
  | None -> Without_role
  | Some role ->
      (match kind_of_stored point.kind with
       | None -> Kind_not_written point.observed_at
       | Some kind ->
           Restorable
             ( point.observed_at
             , { Usage.limit_id = point.limit_id
               ; kind
               ; role
               ; utilization = point.utilization
               ; resets_at = point.resets_at
               } ))

(* The latest reading of each window its source's latest complete snapshot
   still states. *)
let stated_points (held : source_day) =
  Window_map.fold
    (fun _ (point : point) points ->
      match held.snapshot with
      | Some snapshot when point.observed_at < snapshot.observed_at -> points
      | Some _ | None -> point :: points)
    held.windows []

let reports_of_stated source (held : source_day) readings =
  match readings, held.snapshot with
  | [], Some { observed_at; state = Reported_no_windows } ->
      [ Report { observed_at; report = { Usage.source; windows = [] } } ]
  | [], (Some { state = Reported; _ } | None) -> []
  | _ :: _, _ ->
      List.map
        (fun (observed_at, report) -> Report { observed_at; report })
        (reports_of_readings source readings)

(* A sparse report states some windows, so each reading stands on its own. *)
let sparse_reports source held =
  let readings, unrestorable =
    List.fold_left
      (fun (readings, unrestorable) point ->
        match reading_of_point point with
        | Restorable (observed_at, window) -> (observed_at, window) :: readings, unrestorable
        | Without_role -> readings, unrestorable
        | Kind_not_written _ -> readings, unrestorable + 1)
      ([], 0) (stated_points held)
  in
  reports_of_stated source held readings, unrestorable

type complete_readings =
  | All_restorable of (float * Usage.window) list
  | Some_without_role
  | Some_kind_not_written of { observed_at : float; count : int }

(* A complete report says every window its source holds, and a window it
   leaves out is one the provider no longer states. The rows of one that
   could be read in part say less than the report did, so they are not a
   report: nothing of the source is put back, neither those rows nor the
   earlier reports that report replaced. *)
let complete_reports source held =
  let points = stated_points held in
  let latest =
    List.fold_left
      (fun latest (point : point) -> Float.max latest point.observed_at)
      (match held.snapshot with
       | Some snapshot -> snapshot.observed_at
       | None -> Float.neg_infinity)
      points
  in
  match held.unread_at with
  | Some unread_at when unread_at >= latest ->
      [ Unreadable_complete_report { source; observed_at = unread_at } ], 0
  | (Some _ | None) as unread_at ->
      let points =
        match unread_at with
        | None -> points
        | Some unread_at ->
            (* A later report was read whole and replaces the unread one. *)
            List.filter (fun (point : point) -> point.observed_at > unread_at) points
      in
      let readings =
        List.fold_left
          (fun readings point ->
            match readings, reading_of_point point with
            | All_restorable held, Restorable (observed_at, window) ->
                All_restorable ((observed_at, window) :: held)
            | (All_restorable _ | Some_without_role), Without_role -> Some_without_role
            | Some_without_role, Restorable _ -> Some_without_role
            | (All_restorable _ | Some_without_role), Kind_not_written observed_at ->
                Some_kind_not_written { observed_at; count = 1 }
            | Some_kind_not_written unread, Kind_not_written observed_at ->
                Some_kind_not_written
                  { observed_at = Float.max unread.observed_at observed_at
                  ; count = unread.count + 1
                  }
            | (Some_kind_not_written _ as unread), (Restorable _ | Without_role) -> unread)
          (All_restorable []) points
      in
      (match readings with
       | All_restorable readings -> reports_of_stated source held readings, 0
       | Some_without_role -> [], 0
       | Some_kind_not_written { observed_at; count } ->
           [ Unreadable_complete_report { source; observed_at } ], count)

let stored_reports t =
  Scope_source_map.fold
    (fun (scope_id, source_word) (held : source_day) (stored : stored_reports) ->
      match Usage.source_of_string source_word with
      | None ->
          { stored with unrestorable = stored.unrestorable + Window_map.cardinal held.windows }
      | Some source ->
          let reports, unrestorable =
            match Usage.report_shape source with
            | Usage.Sparse_update -> sparse_reports source held
            | Usage.Complete_snapshot -> complete_reports source held
          in
          { reports = stored.reports @ List.map (fun report -> scope_id, report) reports
          ; unrestorable = stored.unrestorable + unrestorable
          })
    (latest_by_source t)
    { reports = []; unrestorable = 0 }

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
  |> List.sort (fun (s1, t1) (s2, t2) ->
       let c = String.compare s1 s2 in
       if c <> 0 then c else Float.compare t1 t2)
  |> List.map (fun (scope_id, observed_at) ->
      `Assoc [ "scope_id", `String scope_id; "observed_at", `Float observed_at ])

let response_json ~days t =
  let daily = daily_points t in
  let points =
    Display_day_map.fold (fun _ point points -> point :: points) daily []
    |> List.sort (fun (a : point) (b : point) ->
        let c = String.compare a.scope_id b.scope_id in
        if c <> 0 then c
        else
          let c = String.compare a.kind b.kind in
          if c <> 0 then c
          else
            let c = Option.compare String.compare a.limit_id b.limit_id in
            if c <> 0 then c else Float.compare a.observed_at b.observed_at)
  in
  `Assoc
    [ "days", `Int days
    ; "generated_at", `Float t.now
    ; "sampling", `String "latest_provider_report_per_utc_day"
    ; "unreadable_reports", `Int t.unreadable_reports
    ; "reported_no_windows", `List (empty_reports t daily)
    ; "points", `List (List.map point_json points)
    ]
