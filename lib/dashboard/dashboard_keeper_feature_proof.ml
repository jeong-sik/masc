(** Dashboard keeper feature proof report.

    This read model is intentionally narrow: it does not claim a feature
    works from configuration alone. A feature is proved only when runtime
    keeper meta or tool-call quality records show recent executable use. *)

type status = Pass | Warn | Fail

type tool_stat = {
  name : string;
  calls : int;
  success_pct : float;
}

type keeper_snapshot = {
  keeper_name : string;
  meta : Keeper_types.keeper_meta option;
  read_error : string option;
}

module Decision = Dashboard_keeper_decision_log_proof
module Failure = Dashboard_keeper_tool_failure_proof
module Git_pr = Dashboard_keeper_git_pr_proof

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

let clamp_float ~low ~high value =
  max low (min high value)

let json_string_list values =
  `List (List.map (fun value -> `String value) values)

let evidence_ref ~kind ~id ~value =
  `Assoc [
    ("kind", `String kind);
    ("id", `String id);
    ("value", `String value);
  ]

let route_evidence path =
  evidence_ref ~kind:"route" ~id:path ~value:path

let keeper_meta_evidence =
  evidence_ref ~kind:"store" ~id:"keeper_meta" ~value:"Keeper_types.read_meta"

let tool_stat_json ?failure_classes stat =
  let fields = [
    ("name", `String stat.name);
    ("calls", `Int stat.calls);
    ("success_pct", `Float stat.success_pct);
  ] in
  match failure_classes with
  | Some classes -> `Assoc (fields @ [("failure_classes", classes)])
  | None -> `Assoc fields

let tool_stat_of_keeper_stat (stat : Failure.tool_keeper_stat) =
  { name = stat.name; calls = stat.calls; success_pct = stat.success_pct }

let latest_success_after_last_failure (stat : Failure.tool_keeper_stat) =
  match stat.latest_success_ts with
  | None -> false
  | Some latest_success ->
    (match stat.latest_failure_ts with
     | None -> true
     | Some latest_failure -> latest_success >= latest_failure)

let accepts_latest_recovery (spec : Dashboard_keeper_feature_catalog.feature_spec) =
  String.equal spec.id "approval_tools"

let tool_stat_passes ~success_threshold_pct spec
    (stat : Failure.tool_keeper_stat) =
  stat.calls > 0
  && (stat.success_pct >= success_threshold_pct
      || (accepts_latest_recovery spec
          && latest_success_after_last_failure stat))

let uniq_sorted names =
  names
  |> List.filter (fun name -> String.trim name <> "")
  |> List.sort_uniq String.compare

let load_keeper_snapshots config =
  Keeper_types.keeper_names config
  |> uniq_sorted
  |> List.map (fun keeper_name ->
    match Keeper_types.read_meta config keeper_name with
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

let snapshot_keeper_names snapshots =
  snapshots
  |> List.map (fun snapshot -> snapshot.keeper_name)
  |> uniq_sorted

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
    ("required_tools", `List []);
    ("passing_tools", `List []);
    ("weak_tools", `List []);
    ("missing_tools", `List []);
    ("keeper_evidence",
     `Assoc [
       ("keeper_count", `Int (keeper_count snapshots));
       ("meta_count", `Int (count_meta snapshots));
       ("observed_keepers", json_string_list observed_keepers);
       ("missing_keepers", json_string_list missing_keepers);
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
    ~predicate:(fun meta -> meta.Keeper_types.runtime.usage.total_turns > 0)
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
    ("required_tools", `List []);
    ("passing_tools", `List []);
    ("weak_tools", `List []);
    ("missing_tools", `List []);
    ("keeper_evidence",
     `Assoc [
       ("keeper_count", `Int total);
       ("meta_count", `Int (count_meta snapshots));
       ( "required_span_hours",
         `Float Decision.persistent_turn_window_hours );
       ( "max_latest_age_hours",
         `Float Decision.recent_turn_max_age_hours );
       ("observed_keepers", json_string_list observed);
       ("missing_keepers", json_string_list missing);
       ("read_errors", `List (keeper_read_errors snapshots));
       ("per_keeper", `List per_keeper);
     ]);
    ( "evidence_refs",
      `List [
        evidence_ref ~kind:"store" ~id:"keeper_decision_log"
          ~value:"Keeper_types.keeper_decision_log_path";
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
       meta.Keeper_types.runtime.autonomous_action_count > 0
       && meta.Keeper_types.runtime.autonomous_tool_turn_count > 0)
    ~summary_label:"keepers have autonomous action and tool-turn counters"
    ~evidence_refs:[keeper_meta_evidence; route_evidence "/api/v1/dashboard/safe-autonomy"]
    ~next_action:
      "Run or repair keepers until each active keeper records autonomous tool-turn counters."

let board_reactive_feature snapshots =
  meta_counter_feature snapshots
    ~id:"board_reactive_autonomy"
    ~label:"Board-reactive turns"
    ~eligible:(fun _snapshot -> true)
    ~predicate:(fun meta -> meta.Keeper_types.runtime.board_reactive_turn_count > 0)
    ~summary_label:"keepers have board-reactive turn counters"
    ~evidence_refs:[keeper_meta_evidence; route_evidence "/api/v1/dashboard/board"]
    ~next_action:
      "Post board events and confirm every active keeper records board-reactive turns."

let scheduled_proactive_feature ~config snapshots =
  let decision_stats =
    snapshots
    |> List.map (fun snapshot ->
      snapshot.keeper_name,
      Decision.scheduled_stats ~config snapshot.keeper_name)
  in
  let decision_stat_for keeper_name =
    List.assoc_opt keeper_name decision_stats
    |> Option.value ~default:Decision.empty_scheduled_stat
  in
  let enabled =
    snapshots
    |> List.filter (fun snapshot ->
      match snapshot.meta with
      | Some meta -> meta.Keeper_types.proactive.enabled
      | None -> false)
  in
  let total = keeper_count enabled in
  let has_scheduled_evidence snapshot meta =
    meta.Keeper_types.runtime.proactive_rt.count_total > 0
    || (decision_stat_for snapshot.keeper_name).decision_count > 0
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
        | Some meta -> meta.Keeper_types.runtime.proactive_rt.count_total
        | None -> 0
      in
      `Assoc [
        ("keeper", `String snapshot.keeper_name);
        ("meta_proactive_count_total", `Int meta_count);
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
          "%d/%d proactive-enabled keepers have scheduled proactive evidence"
          (List.length observed) total));
    ("required_tools", `List []);
    ("passing_tools", `List []);
    ("weak_tools", `List []);
    ("missing_tools", `List []);
    ("keeper_evidence",
     `Assoc [
       ("keeper_count", `Int (keeper_count enabled));
       ("meta_count", `Int (count_meta enabled));
       ("observed_keepers", json_string_list observed);
       ("missing_keepers", json_string_list missing);
       ("read_errors", `List (keeper_read_errors enabled));
       ("per_keeper", `List per_keeper);
     ]);
    ( "evidence_refs",
      `List [
        keeper_meta_evidence;
        evidence_ref ~kind:"store" ~id:"keeper_decision_log"
          ~value:"Keeper_types.keeper_decision_log_path";
        route_evidence "/api/v1/dashboard/execution";
      ] );
    ( "next_action",
      `String
        "Fix scheduler or per-keeper blockers until every proactive-enabled keeper has meta or decision-log evidence for scheduled autonomous cycles." );
  ]

let tool_feature_json
      ~success_threshold_pct
      ~keeper_names
      failure_table
      (tool_stats : (string, Failure.tool_keeper_stat) Hashtbl.t)
      (spec : Dashboard_keeper_feature_catalog.feature_spec)
  =
  let passing, weak, missing =
    spec.required_tools
    |> List.fold_left (fun (passing, weak, missing) tool_name ->
      match Hashtbl.find_opt tool_stats tool_name with
      | Some (keeper_stat : Failure.tool_keeper_stat)
        when tool_stat_passes ~success_threshold_pct spec keeper_stat ->
        let stat = tool_stat_of_keeper_stat keeper_stat in
        (stat :: passing, weak, missing)
      | Some (keeper_stat : Failure.tool_keeper_stat) when keeper_stat.calls > 0 ->
        let stat = tool_stat_of_keeper_stat keeper_stat in
        (passing, stat :: weak, missing)
      | _ -> (passing, weak, tool_name :: missing))
      ([], [], [])
  in
  let passing = List.rev passing in
  let weak = List.rev weak in
  let missing = List.rev missing in
  let required_count = List.length spec.required_tools in
  let status =
    if required_count > 0 && List.length passing = required_count then Pass
    else if passing <> [] || weak <> [] then Warn
    else Fail
  in
  `Assoc [
    ("id", `String spec.id);
    ("label", `String spec.label);
    ("status", `String (status_to_string status));
    ("summary",
     `String
       (Printf.sprintf
          "%d/%d required tools meet %.1f%% success threshold%s; %d weak; %d missing"
          (List.length passing)
          required_count
          success_threshold_pct
          (if accepts_latest_recovery spec
           then " or latest-success recovery"
           else "")
          (List.length weak)
          (List.length missing)));
    ("required_tools", json_string_list spec.required_tools);
    ("passing_tools", `List (List.map tool_stat_json passing));
    ( "weak_tools",
      `List
        (List.map
           (fun stat ->
              tool_stat_json
                ~failure_classes:(Failure.classes_json failure_table stat.name)
                stat)
           weak) );
    ("missing_tools", json_string_list missing);
    ( "keeper_evidence",
      Failure.keeper_evidence_json tool_stats
        ~keeper_names ~required_tools:spec.required_tools );
    ( "evidence_refs",
      `List [
        route_evidence "/api/v1/dashboard/tool-quality";
        evidence_ref ~kind:"store" ~id:"keeper_tool_call_log"
          ~value:"Keeper_tool_call_log.read_recent/read_window";
      ] );
    ("next_action", `String spec.next_action);
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

let keeper_tool_sample_summary
      (tool_stats : (string, Failure.tool_keeper_stat) Hashtbl.t)
  =
  let calls, successes =
    Hashtbl.fold
      (fun _tool_name (stat : Failure.tool_keeper_stat) (calls, successes) ->
         (calls + stat.calls, successes + stat.successes))
      tool_stats
      (0, 0)
  in
  let success_rate =
    if calls = 0 then 0.0
    else
      let pct = Float.of_int successes /. Float.of_int calls *. 100.0 in
      Float.round (pct *. 100.0) /. 100.0
  in
  calls, success_rate

let json
      ~config
      ?(n = 5000)
      ?window_hours
      ?(success_threshold_pct = 80.0)
      ?now
      ()
  =
  let now = Option.value ~default:(Unix.gettimeofday ()) now in
  let success_threshold_pct =
    clamp_float ~low:0.0 ~high:100.0 success_threshold_pct
  in
  let snapshots = load_keeper_snapshots config in
  let keeper_names = snapshot_keeper_names snapshots in
  let tool_stats, failure_table =
    Failure.keeper_stats_and_failures_by_tool ~n ?window_hours ~keeper_names ()
  in
  let features =
    [
      runtime_liveness_feature snapshots;
      persistent_turn_exchange_feature ~config ~now snapshots;
      autonomous_tool_feature snapshots;
      board_reactive_feature snapshots;
      scheduled_proactive_feature ~config snapshots;
      Git_pr.json ~n ?window_hours ~keeper_names ();
    ]
    @ List.map
        (tool_feature_json ~success_threshold_pct ~keeper_names failure_table
           tool_stats)
        Dashboard_keeper_feature_catalog.tool_features
  in
  let statuses = List.map status_of_feature_json features in
  let overall = overall_status statuses in
  let pass_count = count_status Pass statuses in
  let warn_count = count_status Warn statuses in
  let fail_count = count_status Fail statuses in
  let tool_sample_total, tool_sample_success_rate =
    keeper_tool_sample_summary tool_stats
  in
  `Assoc [
    ("generated_at", `String (Masc_domain.now_iso ()));
    ("status", `String (status_to_string overall));
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
       ("tool_sample_total", `Int tool_sample_total);
       ("tool_sample_success_rate", `Float tool_sample_success_rate);
       ("success_threshold_pct", `Float success_threshold_pct);
     ]);
    ("tool_quality",
     `Assoc [
       ("route", `String "/api/v1/dashboard/tool-quality");
       ("scope", `String "known_keepers");
       ("sample_total", `Int tool_sample_total);
       ("success_rate", `Float tool_sample_success_rate);
       ("sampling_mode",
        `String
          (match window_hours with
           | Some _ -> "window_hours"
           | None -> "recent_n"));
       ("sample_limit",
        (match window_hours with
         | Some _ -> `Null
         | None -> `Int n));
       ("window_hours",
        (match window_hours with
         | Some hours -> `Float hours
         | None -> `Null));
     ]);
    ("features", `List features);
    ("evidence_refs",
     `List [
       route_evidence "/api/v1/dashboard/tool-quality";
       route_evidence "/api/v1/dashboard/safe-autonomy";
       route_evidence "/api/v1/dashboard/execution";
       keeper_meta_evidence;
     ]);
  ]
