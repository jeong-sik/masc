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

type feature_spec = {
  id : string;
  label : string;
  required_tools : string list;
  next_action : string;
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

let scheduled_proactive_feature snapshots =
  meta_counter_feature snapshots
    ~id:"scheduled_proactive_autonomy"
    ~label:"Scheduled proactive cycles"
    ~eligible:(fun snapshot ->
      match snapshot.meta with
      | Some meta -> meta.Keeper_types.proactive.enabled
      | None -> false)
    ~predicate:(fun meta -> meta.Keeper_types.runtime.proactive_rt.count_total > 0)
    ~summary_label:"proactive-enabled keepers have scheduled proactive cycles"
    ~evidence_refs:[keeper_meta_evidence; route_evidence "/api/v1/dashboard/execution"]
    ~next_action:
      "Fix scheduler or per-keeper blockers until every proactive-enabled keeper has proactive_count_total > 0."

let tool_features =
  [
    {
      id = "base_tools";
      label = "Base context tools";
      required_tools = [
        "keeper_time_now";
        "keeper_context_status";
        "keeper_memory_search";
      ];
      next_action =
        "Exercise base keeper context tools and repair missing tool-call evidence.";
    };
    {
      id = "board_tools";
      label = "Board tools";
      required_tools = [
        "keeper_board_get";
        "keeper_board_list";
        "keeper_board_post";
        "keeper_board_comment";
        "keeper_board_vote";
      ];
      next_action =
        "Run a board workflow that reads, lists, posts, comments, and votes successfully.";
    };
    {
      id = "filesystem_tools";
      label = "Filesystem tools";
      required_tools = [
        "keeper_fs_read";
        "keeper_fs_edit";
      ];
      next_action =
        "Run sandboxed filesystem read/edit probes and inspect failures for sandbox-path drift.";
    };
    {
      id = "shell_tools";
      label = "Shell tools";
      required_tools = [
        "keeper_shell";
        "keeper_bash";
      ];
      next_action =
        "Run read-only and execution shell probes under the keeper sandbox policy.";
    };
    {
      id = "library_tools";
      label = "Library tools";
      required_tools = [
        "keeper_library_search";
        "keeper_library_read";
      ];
      next_action =
        "Exercise library search/read from an autonomous keeper turn.";
    };
    {
      id = "taskboard_tools";
      label = "Taskboard tools";
      required_tools = [
        "keeper_tasks_list";
        "keeper_tasks_audit";
        "keeper_task_claim";
        "keeper_task_done";
        "keeper_task_submit_for_verification";
        "keeper_task_force_release";
        "keeper_task_create";
      ];
      next_action =
        "Run a claim-to-verification task lifecycle and prove each taskboard tool succeeds.";
    };
    {
      id = "governance_tools";
      label = "Governance tools";
      required_tools = [
        "masc_governance_status";
        "masc_governance_feed";
        "masc_case_status";
        "masc_case_brief_submit";
        "masc_petition_submit";
      ];
      next_action =
        "Run a governance petition/status/readback workflow and capture tool-call evidence.";
    };
    {
      id = "approval_tools";
      label = "Approval tools";
      required_tools = [
        "masc_approval_pending";
        "masc_approval_get";
        "masc_approval_resolve";
      ];
      next_action =
        "Create an approval request and prove pending/get/resolve paths through keeper tools.";
    };
    {
      id = "coding_tools";
      label = "Coding and worktree tools";
      required_tools = [
        "masc_worktree_create";
        "masc_worktree_list";
        "masc_code_search";
        "masc_code_symbols";
        "masc_code_read";
        "masc_code_write";
        "masc_code_edit";
        "masc_code_git";
        "masc_code_shell";
      ];
      next_action =
        "Run a bounded keeper coding task and repair weak worktree/code-write/code-shell paths.";
    };
    {
      id = "pr_review_tools";
      label = "PR and review tools";
      required_tools = [
        "keeper_pr_list";
        "keeper_pr_status";
        "keeper_pr_create";
        "keeper_pr_review_read";
        "keeper_pr_review_comment";
        "keeper_pr_review_reply";
        "keeper_preflight_check";
      ];
      next_action =
        "Exercise PR creation/status/review read-comment-reply with keeper credentials.";
    };
    {
      id = "autoresearch_tools";
      label = "Autoresearch tools";
      required_tools = [
        "masc_autoresearch_start";
        "masc_autoresearch_status";
        "masc_autoresearch_cycle";
        "masc_autoresearch_inject";
        "masc_autoresearch_record_finding";
        "masc_autoresearch_search_findings";
        "masc_autoresearch_stop";
      ];
      next_action =
        "Run an autoresearch loop and prove start/status/cycle/finding/stop paths.";
    };
  ]

let tool_feature_json ~success_threshold_pct tool_stats spec =
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
      scheduled_proactive_feature snapshots;
    ]
    @ List.map
        (tool_feature_json ~success_threshold_pct tool_stats)
        tool_features
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
