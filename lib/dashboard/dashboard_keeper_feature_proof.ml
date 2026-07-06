(** Dashboard keeper feature proof report.

    This read model is intentionally narrow: it does not claim a feature
    works from configuration alone. A feature is proved only when persisted
    runtime keeper meta or decision-log evidence shows current behavior. *)

type status = Pass | Warn | Fail

type keeper_snapshot = {
  keeper_name : string;
  meta : Keeper_meta_contract.keeper_meta option;
  read_error : string option;
}

type keeper_snapshot_scan = {
  snapshots : keeper_snapshot list;
  keeper_names_known : bool;
  read_errors : Yojson.Safe.t list;
}

module Decision = Dashboard_keeper_decision_log_proof

let status_to_string = function
  | Pass -> "pass"
  | Warn -> "warn"
  | Fail -> "fail"

let status_rank = function
  | Pass -> 0
  | Warn -> 1
  | Fail -> 2

let overall_status statuses =
  if List.exists (( = ) Fail) statuses then Fail
  else if List.exists (( = ) Warn) statuses then Warn
  else Pass

let evidence_ref ~kind ~id ~value =
  `Assoc [
    ("kind", `String kind);
    ("id", `String id);
    ("value", `String value);
  ]

let route_evidence path =
  evidence_ref ~kind:"route" ~id:path ~value:path

let keeper_meta_evidence =
  evidence_ref ~kind:"store" ~id:"keeper_meta" ~value:"Keeper_meta_store.read_meta"

let uniq_sorted names =
  names
  |> List.filter (fun name -> String.trim name <> "")
  |> List.sort_uniq String.compare

let keeper_name_discovery_error_json err =
  `Assoc [
    ("source", `String "keeper_names_result");
    ("error", `String err);
  ]

let load_keeper_snapshots config =
  match Keeper_meta_store.keeper_names_result config with
  | Error err ->
    {
      snapshots = [];
      keeper_names_known = false;
      read_errors = [ keeper_name_discovery_error_json err ];
    }
  | Ok keeper_names ->
    let snapshots =
      keeper_names
      |> uniq_sorted
      |> List.map (fun keeper_name ->
    match Keeper_meta_store.read_meta config keeper_name with
    | Ok (Some meta) -> { keeper_name; meta = Some meta; read_error = None }
    | Ok None ->
      {
        keeper_name;
        meta = None;
        read_error = Some "keeper meta missing";
      }
    | Error err ->
      {
        keeper_name;
        meta = None;
        read_error = Some err;
      })
    in
    { snapshots; keeper_names_known = true; read_errors = [] }

let keeper_read_errors snapshots =
  snapshots
  |> List.filter_map (fun snapshot ->
    match snapshot.read_error with
    | None -> None
    | Some error ->
      Some (`Assoc [
        ("keeper", `String snapshot.keeper_name);
        ("error", `String error);
      ]))

let keeper_count snapshots = List.length snapshots

let count_meta snapshots =
  snapshots
  |> List.filter (fun snapshot -> Option.is_some snapshot.meta)
  |> List.length

let meta_feature_json
      ~id
      ~label
      ~status
      ~summary
      ~observed_keepers
      ~missing_keepers
      ~evidence_refs
      ~next_action
      snapshots
  =
  `Assoc [
    ("id", `String id);
    ("label", `String label);
    ("status", `String (status_to_string status));
    ("summary", `String summary);
    ("keeper_evidence",
     `Assoc [
       ("keeper_count", `Int (keeper_count snapshots));
       ("meta_count", `Int (count_meta snapshots));
       ("observed_keepers", Json_util.json_string_list observed_keepers);
       ("missing_keepers", Json_util.json_string_list missing_keepers);
       ("read_errors", `List (keeper_read_errors snapshots));
     ]);
    ("evidence_refs", `List evidence_refs);
    ("next_action", `String next_action);
  ]

let meta_counter_feature
      snapshots
      ~id
      ~label
      ~eligible
      ~predicate
      ~summary_label
      ~evidence_refs
      ~next_action
  =
  let eligible_snapshots = List.filter eligible snapshots in
  let total = keeper_count eligible_snapshots in
  let observed =
    eligible_snapshots
    |> List.filter_map (fun snapshot ->
      match snapshot.meta with
      | Some meta when predicate meta -> Some snapshot.keeper_name
      | _ -> None)
    |> uniq_sorted
  in
  let missing =
    eligible_snapshots
    |> List.filter_map (fun snapshot ->
      match snapshot.meta with
      | Some meta when predicate meta -> None
      | _ -> Some snapshot.keeper_name)
    |> uniq_sorted
  in
  let status =
    if total = 0 || observed = [] then Fail
    else if List.length observed = total then Pass
    else Warn
  in
  meta_feature_json
    ~id
    ~label
    ~status
    ~summary:
      (Printf.sprintf "%d/%d %s" (List.length observed) total summary_label)
    ~observed_keepers:observed
    ~missing_keepers:missing
    ~evidence_refs
    ~next_action
    eligible_snapshots

let runtime_liveness_feature snapshots =
  meta_counter_feature snapshots
    ~id:"runtime_liveness"
    ~label:"Persisted keeper runtime turns"
    ~eligible:(fun _snapshot -> true)
    ~predicate:(fun meta -> meta.runtime.usage.total_turns > 0)
    ~summary_label:"keepers have persisted runtime turns"
    ~evidence_refs:[keeper_meta_evidence; route_evidence "/api/v1/dashboard/execution"]
    ~next_action:
      "Resume or repair keepers without persisted turns before claiming fleet-wide autonomy."

let persistent_turn_exchange_feature ~config ~now snapshots =
  let stats =
    snapshots
    |> List.map (fun snapshot ->
      snapshot.keeper_name, Decision.turn_span_stats ~config snapshot.keeper_name)
  in
  let decision_read_errors =
    stats
    |> List.concat_map (fun (_, stat) -> Decision.turn_span_read_errors stat)
  in
  let stat_for keeper_name =
    match List.assoc_opt keeper_name stats with
    | Some stat -> stat
    | None -> Decision.turn_span_stats ~config keeper_name
  in
  let observed =
    snapshots
    |> List.filter_map (fun snapshot ->
      if Decision.has_persistent_turn_span ~now (stat_for snapshot.keeper_name) then
        Some snapshot.keeper_name
      else None)
    |> uniq_sorted
  in
  let missing =
    snapshots
    |> List.filter_map (fun snapshot ->
      if Decision.has_persistent_turn_span ~now (stat_for snapshot.keeper_name) then
        None
      else Some snapshot.keeper_name)
    |> uniq_sorted
  in
  let total = keeper_count snapshots in
  let status =
    if total = 0 || observed = [] then Fail
    else if List.length observed = total then Pass
    else Warn
  in
  let per_keeper =
    snapshots
    |> List.map (fun snapshot ->
      Decision.turn_span_evidence_json ~now snapshot.keeper_name
        (stat_for snapshot.keeper_name))
  in
  `Assoc [
    ("id", `String "persistent_24h_turn_exchange");
    ("label", `String "24h persistent turn exchange");
    ("status", `String (status_to_string status));
    ("summary",
     `String
       (Printf.sprintf
          "%d/%d keepers have decision-log turn spans >= %.1fh and latest turn <= %.1fh old"
          (List.length observed) total
          Decision.persistent_turn_window_hours
          Decision.recent_turn_max_age_hours));
    ("keeper_evidence",
     `Assoc [
       ("keeper_count", `Int total);
       ("meta_count", `Int (count_meta snapshots));
       ( "required_span_hours",
         `Float Decision.persistent_turn_window_hours );
       ( "max_latest_age_hours",
         `Float Decision.recent_turn_max_age_hours );
       ("observed_keepers", Json_util.json_string_list observed);
       ("missing_keepers", Json_util.json_string_list missing);
       ("read_errors", `List (keeper_read_errors snapshots @ decision_read_errors));
       ("per_keeper", `List per_keeper);
     ]);
    ("read_errors", `List decision_read_errors);
    ( "evidence_refs",
      `List [
        evidence_ref ~kind:"store" ~id:"keeper_decision_log"
          ~value:"Keeper_types_support.keeper_decision_log_path";
        route_evidence "/api/v1/dashboard/execution";
      ] );
    ( "next_action",
      `String
        "Keep the runtime running until every keeper has decision-log turn evidence spanning at least 24h with a recent latest turn." );
  ]

let autonomous_tool_feature snapshots =
  meta_counter_feature snapshots
    ~id:"autonomous_tool_use"
    ~label:"Autonomous tool turns"
    ~eligible:(fun _snapshot -> true)
    ~predicate:(fun meta ->
       meta.runtime.autonomous_action_count > 0
       && meta.runtime.autonomous_tool_turn_count > 0)
    ~summary_label:"keepers have autonomous action and tool-turn counters"
    ~evidence_refs:[keeper_meta_evidence]
    ~next_action:
      "Run or repair keepers until each active keeper records autonomous tool-turn counters."

let board_reactive_feature snapshots =
  meta_counter_feature snapshots
    ~id:"board_reactive_autonomy"
    ~label:"Board-reactive turns"
    ~eligible:(fun _snapshot -> true)
    ~predicate:(fun meta -> meta.runtime.board_reactive_turn_count > 0)
    ~summary_label:"keepers have board-reactive turn counters"
    ~evidence_refs:[keeper_meta_evidence; route_evidence "/api/v1/dashboard/board"]
    ~next_action:
      "Post board events and confirm every active keeper records board-reactive turns."

let timestamp_within_window ?window_hours ~now ts =
  (* Reject zero/negative timestamps (marker/unset) and future timestamps
     (clock skew or corrupted logs). Without the [ts <= now] guard, any
     future timestamp would satisfy the recency check because [now -. ts]
     would be negative and trivially [<= hours *. 3600.0]. *)
  ts > 0.0
  && ts <= now
  &&
  match window_hours with
  | None -> true
  | Some hours when hours <= 0.0 ->
    (* Non-positive window is treated as "no recency check": flipping it
       to a hard reject would silently disqualify all past evidence. The
       top-level [json] helper clamps callers' inputs to a sane domain;
       this keeps internal logic robust if a caller bypasses the boundary. *)
    true
  | Some hours -> now -. ts <= hours *. Masc_time_constants.hour

let scheduled_proactive_feature ~config ?window_hours ~now snapshots =
  let enabled =
    snapshots
    |> List.filter (fun snapshot ->
      match snapshot.meta with
      | Some meta -> meta.proactive.enabled
      | None -> false)
  in
  let decision_stats =
    enabled
    |> List.map (fun snapshot ->
      snapshot.keeper_name,
      Decision.scheduled_stats ~config snapshot.keeper_name)
  in
  let decision_read_errors =
    decision_stats
    |> List.concat_map (fun (_, stat) -> Decision.scheduled_read_errors stat)
  in
  let decision_stat_for keeper_name =
    List.assoc_opt keeper_name decision_stats
    |> Option.value ~default:Decision.empty_scheduled_stat
  in
  let total = keeper_count enabled in
  let has_recent_meta_evidence meta =
    meta.Keeper_meta_contract.runtime.proactive_rt.count_total > 0
    && timestamp_within_window ?window_hours ~now
         meta.Keeper_meta_contract.runtime.proactive_rt.last_ts
    && not
         (meta.Keeper_meta_contract.runtime.proactive_rt.last_outcome
          = Keeper_meta_contract.Proactive_error)
  in
  let has_recent_decision_evidence snapshot =
    match (decision_stat_for snapshot.keeper_name).latest_ts_unix with
    | Some ts -> timestamp_within_window ?window_hours ~now ts
    | None -> false
  in
  let has_scheduled_evidence snapshot meta =
    has_recent_meta_evidence meta || has_recent_decision_evidence snapshot
  in
  let observed =
    enabled
    |> List.filter_map (fun snapshot ->
      match snapshot.meta with
      | Some meta when has_scheduled_evidence snapshot meta ->
        Some snapshot.keeper_name
      | _ -> None)
    |> uniq_sorted
  in
  let missing =
    enabled
    |> List.filter_map (fun snapshot ->
      match snapshot.meta with
      | Some meta when has_scheduled_evidence snapshot meta -> None
      | _ -> Some snapshot.keeper_name)
    |> uniq_sorted
  in
  let status =
    if total = 0 || observed = [] then Fail
    else if List.length observed = total then Pass
    else Warn
  in
  let per_keeper =
    enabled
    |> List.map (fun snapshot ->
      let stat = decision_stat_for snapshot.keeper_name in
      let meta_count =
        match snapshot.meta with
        | Some meta -> meta.Keeper_meta_contract.runtime.proactive_rt.count_total
        | None -> 0
      in
      let meta_last_ts =
        match snapshot.meta with
        | Some meta -> meta.Keeper_meta_contract.runtime.proactive_rt.last_ts
        | None -> 0.0
      in
      let meta_recent =
        match snapshot.meta with
        | Some meta -> has_recent_meta_evidence meta
        | None -> false
      in
      let meta_outcome =
        match snapshot.meta with
        | Some meta ->
          Some
            (Keeper_meta_contract.proactive_cycle_outcome_to_string
               meta.Keeper_meta_contract.runtime.proactive_rt.last_outcome)
        | None -> None
      in
      `Assoc [
        ("keeper", `String snapshot.keeper_name);
        ("meta_proactive_count_total", `Int meta_count);
        ( "meta_last_proactive_ts",
          if meta_last_ts > 0.0 then `Float meta_last_ts else `Null );
        ( "meta_last_proactive_outcome",
          Json_util.string_opt_to_json meta_outcome );
        ("meta_evidence_within_window", `Bool meta_recent);
        ("decision_log", Decision.scheduled_evidence_json stat);
      ])
  in
  `Assoc [
    ("id", `String "scheduled_proactive_autonomy");
    ("label", `String "Scheduled proactive cycles");
    ("status", `String (status_to_string status));
    ("summary",
     `String
       (Printf.sprintf
          "%d/%d proactive-enabled keepers have scheduled proactive evidence%s"
          (List.length observed) total
          (match window_hours with
           | Some hours -> Printf.sprintf " in the last %.1fh" hours
           | None -> "")));
    ("keeper_evidence",
     `Assoc [
       ("keeper_count", `Int (keeper_count enabled));
       ("meta_count", `Int (count_meta enabled));
       ("observed_keepers", Json_util.json_string_list observed);
       ("missing_keepers", Json_util.json_string_list missing);
       ("read_errors", `List (keeper_read_errors enabled @ decision_read_errors));
       ("per_keeper", `List per_keeper);
     ]);
    ("read_errors", `List decision_read_errors);
    ( "evidence_refs",
      `List [
        keeper_meta_evidence;
        evidence_ref ~kind:"store" ~id:"keeper_decision_log"
          ~value:"Keeper_types_support.keeper_decision_log_path";
        route_evidence "/api/v1/dashboard/execution";
      ] );
    ( "next_action",
      `String
        "Fix scheduler or per-keeper blockers until every proactive-enabled keeper has meta or decision-log evidence for scheduled autonomous cycles." );
  ]

let status_of_feature_json json =
  match Safe_ops.json_string_opt "status" json with
  | Some "pass" -> Pass
  | Some "warn" -> Warn
  | Some "fail" -> Fail
  | _ -> Fail

let count_status needle statuses =
  statuses
  |> List.filter (fun status -> status_rank status = status_rank needle)
  |> List.length

let feature_read_errors json =
  match Json_util.assoc_member_opt "read_errors" json with
  | Some (`List errors) -> errors
  | _ -> []

let json ~config ?window_hours ?now () =
  let now = Option.value ~default:(Unix.gettimeofday ()) now in
  (* Normalize at the public boundary so feature helpers never see a
     non-positive window. Callers passing [Some h] with [h <= 0.0] from
     CLI/config are treated the same as [None] (no recency check)
     instead of producing surprising "negative window rejects all"
     semantics. *)
  let window_hours =
    match window_hours with
    | Some h when h > 0.0 -> Some h
    | Some _ | None -> None
  in
  let snapshot_scan = load_keeper_snapshots config in
  let snapshots = snapshot_scan.snapshots in
  let features =
    [
      runtime_liveness_feature snapshots;
      persistent_turn_exchange_feature ~config ~now snapshots;
      autonomous_tool_feature snapshots;
      board_reactive_feature snapshots;
      scheduled_proactive_feature ~config ?window_hours ~now snapshots;
    ]
  in
  let read_errors =
    snapshot_scan.read_errors @ List.concat_map feature_read_errors features
  in
  let statuses = List.map status_of_feature_json features in
  let overall = overall_status statuses in
  let pass_count = count_status Pass statuses in
  let warn_count = count_status Warn statuses in
  let fail_count = count_status Fail statuses in
  `Assoc [
    ("generated_at", `String (Masc_domain.now_iso ()));
    ("status", `String (status_to_string overall));
    ("keeper_names_known", `Bool snapshot_scan.keeper_names_known);
    ("read_error_count", `Int (List.length read_errors));
    ("read_errors", `List read_errors);
    ("summary",
     `Assoc [
       ("status", `String (status_to_string overall));
       ("feature_count", `Int (List.length features));
       ("pass_count", `Int pass_count);
       ("warn_count", `Int warn_count);
       ("fail_count", `Int fail_count);
       ("gap_count", `Int (warn_count + fail_count));
       ("keeper_count", `Int (keeper_count snapshots));
       ("keeper_meta_count", `Int (count_meta snapshots));
       ("keeper_names_known", `Bool snapshot_scan.keeper_names_known);
       ("read_error_count", `Int (List.length read_errors));
       ("read_errors", `List read_errors);
       ("window_hours",
        (match window_hours with
         | Some hours -> `Float hours
         | None -> `Null));
     ]);
    ("features", `List features);
    ("evidence_refs",
     `List [
       route_evidence "/api/v1/dashboard/execution";
       keeper_meta_evidence;
     ]);
  ]
