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

type scheduled_decision_stat = {
  decision_count : int;
  latest_ts : string option;
}

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

let assoc_list field json =
  match Yojson.Safe.Util.member field json with
  | `List items -> items
  | _ -> []

let tool_stats_by_name (summary : Yojson.Safe.t) : (string, tool_stat) Hashtbl.t =
  let table = Hashtbl.create 128 in
  assoc_list "by_tool" summary
  |> List.iter (fun row ->
    match Safe_ops.json_string_opt "name" row with
    | None -> ()
    | Some name ->
      let stat =
        {
          name;
          calls = Safe_ops.json_int ~default:0 "calls" row;
          success_pct = Safe_ops.json_float ~default:0.0 "success_pct" row;
        }
      in
      Hashtbl.replace table name stat);
  table

let tool_stat_json stat =
  `Assoc [
    ("name", `String stat.name);
    ("calls", `Int stat.calls);
    ("success_pct", `Float stat.success_pct);
  ]

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

let empty_scheduled_decision_stat = { decision_count = 0; latest_ts = None }

let scheduled_decision_stats ~config keeper_name =
  let path = Keeper_types.keeper_decision_log_path config keeper_name in
  if not (Sys.file_exists path) then empty_scheduled_decision_stat
  else
    match Safe_ops.read_file_safe path with
    | Error _ -> empty_scheduled_decision_stat
    | Ok contents ->
      contents
      |> String.split_on_char '\n'
      |> List.fold_left
           (fun acc line ->
              let line = String.trim line in
              if line = "" then acc
              else
                match Yojson.Safe.from_string line with
                | exception Yojson.Json_error _ -> acc
                | json ->
                  match Safe_ops.json_string_opt "channel" json with
                  | Some "scheduled_autonomous" ->
                    {
                      decision_count = acc.decision_count + 1;
                      latest_ts =
                        (match Safe_ops.json_string_opt "ts" json with
                         | Some ts when String.trim ts <> "" -> Some ts
                         | _ -> acc.latest_ts);
                    }
                  | _ -> acc)
           empty_scheduled_decision_stat

let scheduled_decision_evidence_json stat =
  `Assoc [
    ("decision_count", `Int stat.decision_count);
    ( "latest_ts",
      match stat.latest_ts with
      | Some ts -> `String ts
      | None -> `Null );
  ]

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
    snapshots

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
      scheduled_decision_stats ~config snapshot.keeper_name)
  in
  let decision_stat_for keeper_name =
    List.assoc_opt keeper_name decision_stats
    |> Option.value ~default:empty_scheduled_decision_stat
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
        ("decision_log", scheduled_decision_evidence_json stat);
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
       ("keeper_count", `Int (keeper_count snapshots));
       ("meta_count", `Int (count_meta snapshots));
       ("observed_keepers", json_string_list observed);
       ("missing_keepers", json_string_list missing);
       ("read_errors", `List (keeper_read_errors snapshots));
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
      tool_stats
      (spec : Dashboard_keeper_feature_catalog.feature_spec)
  =
  let passing, weak, missing =
    spec.required_tools
    |> List.fold_left (fun (passing, weak, missing) tool_name ->
      match Hashtbl.find_opt tool_stats tool_name with
      | Some stat when stat.calls > 0 && stat.success_pct >= success_threshold_pct ->
        (stat :: passing, weak, missing)
      | Some stat when stat.calls > 0 ->
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
          "%d/%d required tools meet %.1f%% success threshold; %d weak; %d missing"
          (List.length passing)
          required_count
          success_threshold_pct
          (List.length weak)
          (List.length missing)));
    ("required_tools", json_string_list spec.required_tools);
    ("passing_tools", `List (List.map tool_stat_json passing));
    ("weak_tools", `List (List.map tool_stat_json weak));
    ("missing_tools", json_string_list missing);
    ("keeper_evidence", `Null);
    ("evidence_refs", `List [route_evidence "/api/v1/dashboard/tool-quality"]);
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

let json ~config ?(n = 5000) ?window_hours ?(success_threshold_pct = 80.0) () =
  let success_threshold_pct =
    clamp_float ~low:0.0 ~high:100.0 success_threshold_pct
  in
  let tool_summary = Dashboard_http_tool_quality.aggregate ~n ?window_hours () in
  let tool_stats = tool_stats_by_name tool_summary in
  let snapshots = load_keeper_snapshots config in
  let features =
    [
      runtime_liveness_feature snapshots;
      autonomous_tool_feature snapshots;
      board_reactive_feature snapshots;
      scheduled_proactive_feature ~config snapshots;
    ]
    @ List.map
        (tool_feature_json ~success_threshold_pct tool_stats)
        Dashboard_keeper_feature_catalog.tool_features
  in
  let statuses = List.map status_of_feature_json features in
  let overall = overall_status statuses in
  let pass_count = count_status Pass statuses in
  let warn_count = count_status Warn statuses in
  let fail_count = count_status Fail statuses in
  let tool_sample_total = Safe_ops.json_int ~default:0 "total" tool_summary in
  let tool_sample_success_rate =
    Safe_ops.json_float ~default:0.0 "success_rate" tool_summary
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
       ("sample_total", `Int tool_sample_total);
       ("success_rate", `Float tool_sample_success_rate);
       ("sampling_mode",
        Yojson.Safe.Util.member "sampling_mode" tool_summary);
       ("sample_limit",
        Yojson.Safe.Util.member "sample_limit" tool_summary);
       ("window_hours",
        Yojson.Safe.Util.member "window_hours" tool_summary);
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
