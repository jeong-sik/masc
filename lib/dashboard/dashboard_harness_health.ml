(** Dashboard_harness_health — read model for Lab safety harness.

    Aggregates evaluator calibration stats with recent runtime safety signals
    so the Lab surface can explain what the harness is watching. *)

type rail_status =
  | Healthy
  | Warning
  | Stale
  | Idle

type harness_verdict_item = {
  timestamp : float;
  task_id : string;
  task_title : string;
  agent_name : string;
  gate : string;
  verdict : string;
  evaluator_cascade : string;
  fallback_reason : string option;
}

type pre_compact_event = {
  timestamp : float;
  keeper_name : string;
  context_ratio : float;
  message_count : int;
  token_count : int;
  strategies : string list;
  model_family : string;
  trigger : string;
}

type dna_quality_event = {
  timestamp : float;
  keeper_name : string;
  score : float;
  dimensions : Yojson.Safe.t;
}

let max_runtime_events = 12
let max_recent_verdicts = 8
let max_signal_scan = 500
let runtime_stale_after_s = 30. *. 60.
let evaluator_stale_after_s = 12. *. 3600.

let pre_compact_store_ref : Dated_jsonl.t option ref = ref None
let dna_quality_store_ref : Dated_jsonl.t option ref = ref None

let status_to_string = function
  | Healthy -> "healthy"
  | Warning -> "warning"
  | Stale -> "stale"
  | Idle -> "idle"

let trim_recent (type a) max_items (values : a list) : a list =
  if List.length values <= max_items then values
  else List.filteri (fun idx _ -> idx < max_items) values

let trimmed_env_opt key =
  match Sys.getenv_opt key with
  | Some value ->
      let value = String.trim value in
      if String.equal value "" then None else Some value
  | None -> None

let me_root () =
  match Env_config.me_root_opt () with
  | Some root -> root
  | None -> (
      match trimmed_env_opt "HOME" with
      | Some home -> Filename.concat home "me"
      | None -> Env_config.me_root ())

let pre_compact_store_base_dir () =
  Filename.concat (me_root ()) "data/harness-pre-compact"

let dna_quality_store_base_dir () =
  Filename.concat (me_root ()) "data/harness-dna-quality"

let get_or_create_store store_ref base_dir_fn =
  match !store_ref with
  | Some store -> store
  | None ->
      let store = Dated_jsonl.create ~base_dir:(base_dir_fn ()) () in
      store_ref := Some store;
      store

let get_pre_compact_store () =
  get_or_create_store pre_compact_store_ref pre_compact_store_base_dir

let get_dna_quality_store () =
  get_or_create_store dna_quality_store_ref dna_quality_store_base_dir

let reset_runtime_stores_for_testing () =
  pre_compact_store_ref := None;
  dna_quality_store_ref := None

let set_pre_compact_store_for_testing ~base_dir =
  pre_compact_store_ref := Some (Dated_jsonl.create ~base_dir ())

let set_dna_quality_store_for_testing ~base_dir =
  dna_quality_store_ref := Some (Dated_jsonl.create ~base_dir ())

let json_float_option = function
  | Some value -> `Float value
  | None -> `Null

let json_string_option = function
  | Some value -> `String value
  | None -> `Null

let string_field json key =
  Safe_ops.json_string ~default:"" key json

let is_stale ~threshold_s timestamp =
  (Time_compat.now () -. timestamp) > threshold_s

let date_bounds ?since ?until () =
  let since = match since with Some value -> value | None -> "" in
  let until = match until with Some value -> value | None -> "" in
  (since, until)

let read_store_records store ?since ?until () =
  let since, until = date_bounds ?since ?until () in
  if since = "" && until = "" then
    Dated_jsonl.read_recent store max_signal_scan
  else
    let start_date = if since = "" then "2020-01-01" else since in
    let end_date = if until = "" then "2099-12-31" else until in
    Dated_jsonl.read_range store ~since:start_date ~until:end_date

let has_any_records store =
  Dated_jsonl.read_recent store 1 <> []

let max_timestamp left right =
  match (left, right) with
  | Some l, Some r -> Some (Float.max l r)
  | Some _ as value, None
  | None, (Some _ as value) -> value
  | None, None -> None

let verdict_item_json (item : harness_verdict_item) =
  `Assoc
    [
      ("timestamp", `Float item.timestamp);
      ("task_id", `String item.task_id);
      ("task_title", `String item.task_title);
      ("agent_name", `String item.agent_name);
      ("gate", `String item.gate);
      ("verdict", `String item.verdict);
      ("evaluator_cascade", `String item.evaluator_cascade);
      ("fallback_reason", json_string_option item.fallback_reason);
    ]

let verdict_item_of_json json =
  if not (String.equal (string_field json "record_type") "verdict") then None
  else
    Some
      {
        timestamp = Safe_ops.json_float ~default:0.0 "timestamp" json;
        task_id = string_field json "task_id";
        task_title = string_field json "task_title";
        agent_name = string_field json "agent_name";
        gate = string_field json "gate";
        verdict = string_field json "verdict";
        evaluator_cascade = string_field json "evaluator_cascade";
        fallback_reason = Safe_ops.json_string_opt "fallback_reason" json;
      }

let pre_compact_record_json (event : pre_compact_event) =
  `Assoc
    [
      ("record_type", `String "pre_compact");
      ("timestamp", `Float event.timestamp);
      ("keeper_name", `String event.keeper_name);
      ("context_ratio", `Float event.context_ratio);
      ("message_count", `Int event.message_count);
      ("token_count", `Int event.token_count);
      ("strategies", `List (List.map (fun value -> `String value) event.strategies));
      ("model_family", `String event.model_family);
      ("trigger", `String event.trigger);
    ]

let pre_compact_event_json (event : pre_compact_event) =
  `Assoc
    [
      ("timestamp", `Float event.timestamp);
      ("keeper_name", `String event.keeper_name);
      ("context_ratio", `Float event.context_ratio);
      ("message_count", `Int event.message_count);
      ("token_count", `Int event.token_count);
      ("strategies", `List (List.map (fun value -> `String value) event.strategies));
      ("model_family", `String event.model_family);
      ("trigger", `String event.trigger);
    ]

let pre_compact_event_of_json json =
  let record_type = string_field json "record_type" in
  if record_type <> "" && not (String.equal record_type "pre_compact") then None
  else
    Some
      {
        timestamp = Safe_ops.json_float ~default:0.0 "timestamp" json;
        keeper_name = string_field json "keeper_name";
        context_ratio = Safe_ops.json_float ~default:0.0 "context_ratio" json;
        message_count = Safe_ops.json_int ~default:0 "message_count" json;
        token_count = Safe_ops.json_int ~default:0 "token_count" json;
        strategies = Safe_ops.json_string_list "strategies" json;
        model_family = string_field json "model_family";
        trigger = string_field json "trigger";
      }

let dna_quality_record_json (event : dna_quality_event) =
  `Assoc
    [
      ("record_type", `String "dna_quality");
      ("timestamp", `Float event.timestamp);
      ("keeper_name", `String event.keeper_name);
      ("score", `Float event.score);
      ("dimensions", event.dimensions);
    ]

let dna_quality_event_json (event : dna_quality_event) =
  `Assoc
    [
      ("timestamp", `Float event.timestamp);
      ("keeper_name", `String event.keeper_name);
      ("score", `Float event.score);
      ("dimensions", event.dimensions);
    ]

let dna_quality_event_of_json json =
  let record_type = string_field json "record_type" in
  if record_type <> "" && not (String.equal record_type "dna_quality") then None
  else
    let dimensions =
      match Safe_ops.json_member_opt "dimensions" json with
      | Some value -> value
      | None -> `Assoc []
    in
    Some
      {
        timestamp = Safe_ops.json_float ~default:0.0 "timestamp" json;
        keeper_name = string_field json "keeper_name";
        score = Safe_ops.json_float ~default:0.0 "score" json;
        dimensions;
      }

let read_recent_verdicts ?since ?until ?(limit = max_recent_verdicts) ()
    : harness_verdict_item list =
  let records = read_store_records (Eval_calibration.get_store ()) ?since ?until () in
  let verdicts : harness_verdict_item list =
    records |> List.filter_map verdict_item_of_json
  in
  let verdicts =
    List.sort
      (fun (left : harness_verdict_item) (right : harness_verdict_item) ->
        Float.compare right.timestamp left.timestamp)
      verdicts
  in
  trim_recent limit verdicts

let read_pre_compact_events ?since ?until () =
  let records = read_store_records (get_pre_compact_store ()) ?since ?until () in
  let events : pre_compact_event list =
    records |> List.filter_map pre_compact_event_of_json
  in
  List.sort
    (fun (left : pre_compact_event) (right : pre_compact_event) ->
      Float.compare right.timestamp left.timestamp)
    events

let read_dna_quality_events ?since ?until () =
  let records = read_store_records (get_dna_quality_store ()) ?since ?until () in
  let events : dna_quality_event list =
    records |> List.filter_map dna_quality_event_of_json
  in
  List.sort
    (fun (left : dna_quality_event) (right : dna_quality_event) ->
      Float.compare right.timestamp left.timestamp)
    events

let empty_reason ~has_any ?since ?until () =
  let since, until = date_bounds ?since ?until () in
  if has_any && (since <> "" || until <> "") then Some "window_empty"
  else if has_any then Some "no_recent_events"
  else Some "no_runtime_activity"

let pre_compact_status (latest_event : pre_compact_event option) =
  match latest_event with
  | None -> Idle
  | Some event ->
      if is_stale ~threshold_s:runtime_stale_after_s event.timestamp then Stale
      else if event.context_ratio >= 0.95 || event.token_count >= 50_000 then Warning
      else Healthy

let dna_quality_status (latest_event : dna_quality_event option) =
  match latest_event with
  | None -> Idle
  | Some event ->
      if is_stale ~threshold_s:runtime_stale_after_s event.timestamp then Stale
      else
        let goal_anchor = Safe_ops.json_bool ~default:false "has_goal_anchor" event.dimensions in
        let task_anchor = Safe_ops.json_bool ~default:false "has_task_anchor" event.dimensions in
        let recent_context =
          Safe_ops.json_bool ~default:false "has_recent_context" event.dimensions
        in
        let truncation =
          Safe_ops.json_int ~default:0 "truncation_artifacts" event.dimensions
        in
        if event.score < 0.6 || not goal_anchor || not task_anchor
           || not recent_context || truncation > 0
        then Warning
        else Healthy

let evaluator_status ~calibration latest_timestamp =
  let total_verdicts = Safe_ops.json_int ~default:0 "total_verdicts" calibration in
  let fallback_count = Safe_ops.json_int ~default:0 "fallback_count" calibration in
  if total_verdicts = 0 then Idle
  else
    match latest_timestamp with
    | Some ts when is_stale ~threshold_s:evaluator_stale_after_s ts -> Stale
    | _ ->
        let fallback_ratio =
          float_of_int fallback_count /. float_of_int (max 1 total_verdicts)
        in
        if fallback_ratio > 0.8 then Warning else Healthy

let latest_timestamp_of_verdicts (verdicts : harness_verdict_item list) =
  match verdicts with
  | item :: _ -> Some item.timestamp
  | [] -> None

let latest_by_timestamp timestamp_of items =
  List.fold_left
    (fun acc item ->
      match acc with
      | Some current when timestamp_of current >= timestamp_of item -> acc
      | _ -> Some item)
    None items

let pre_compact_timestamp (event : pre_compact_event) = event.timestamp
let pre_compact_ratio (event : pre_compact_event) = event.context_ratio
let dna_quality_timestamp (event : dna_quality_event) = event.timestamp
let dna_quality_score (event : dna_quality_event) = event.score

let overview_json
    ~(calibration : Yojson.Safe.t)
    ~(recent_verdicts : harness_verdict_item list)
    ~(latest_pre_compact : pre_compact_event option)
    ~(latest_dna : dna_quality_event option) =
  let verdict_last = latest_timestamp_of_verdicts recent_verdicts in
  let pre_compact_last = Option.map pre_compact_timestamp latest_pre_compact in
  let dna_last = Option.map dna_quality_timestamp latest_dna in
  let fallback_count = Safe_ops.json_int ~default:0 "fallback_count" calibration in
  let total_verdicts = Safe_ops.json_int ~default:0 "total_verdicts" calibration in
  let fallback_ratio =
    if total_verdicts = 0 then 0.0
    else float_of_int fallback_count /. float_of_int total_verdicts
  in
  let last_signal_at =
    max_timestamp verdict_last (max_timestamp pre_compact_last dna_last)
  in
  `Assoc
    [
      ( "evaluator_status",
        `String (status_to_string (evaluator_status ~calibration verdict_last)) );
      ( "pre_compact_status",
        `String (status_to_string (pre_compact_status latest_pre_compact)) );
      ("dna_status", `String (status_to_string (dna_quality_status latest_dna)));
      ("last_signal_at", json_float_option last_signal_at);
      ("evaluator_last_event_at", json_float_option verdict_last);
      ("pre_compact_last_event_at", json_float_option pre_compact_last);
      ("dna_last_event_at", json_float_option dna_last);
      ("fallback_ratio", `Float fallback_ratio);
      ( "latest_pre_compact_ratio",
        json_float_option (Option.map pre_compact_ratio latest_pre_compact) );
      ( "latest_dna_score",
        json_float_option (Option.map dna_quality_score latest_dna) );
    ]

let record_pre_compact_at ~timestamp ~keeper_name ~context_ratio ~message_count
    ~token_count ~strategies ~model_family ~trigger =
  let event =
    {
      timestamp;
      keeper_name;
      context_ratio;
      message_count;
      token_count;
      strategies;
      model_family;
      trigger;
    }
  in
  Dated_jsonl.append (get_pre_compact_store ()) (pre_compact_record_json event);
  event

let record_pre_compact ~keeper_name ~context_ratio ~message_count ~token_count
    ~strategies ~model_family ~trigger =
  record_pre_compact_at ~timestamp:(Time_compat.now ()) ~keeper_name
    ~context_ratio ~message_count ~token_count ~strategies ~model_family
    ~trigger

let record_dna_quality_at ~timestamp ~keeper_name ~score ~dimensions =
  let event =
    {
      timestamp;
      keeper_name;
      score;
      dimensions;
    }
  in
  Dated_jsonl.append (get_dna_quality_store ()) (dna_quality_record_json event);
  event

let record_dna_quality ~keeper_name ~score ~dimensions =
  record_dna_quality_at ~timestamp:(Time_compat.now ()) ~keeper_name ~score
    ~dimensions

let recent_verdicts_json ?since ?until () =
  `List (List.map verdict_item_json (read_recent_verdicts ?since ?until ()))

let recent_pre_compact_json ?since ?until ~has_any
    ~(latest : pre_compact_event option) ~(events : pre_compact_event list) () =
  let status = status_to_string (pre_compact_status latest) in
  let recent_events = trim_recent max_runtime_events events in
  `Assoc
    [
      ( "description",
        `String
          "Shows recent context compaction attempts before long-running keeper turns are condensed." );
      ("status", `String status);
      ("last_event_at", json_float_option (Option.map pre_compact_timestamp latest));
      ( "empty_reason",
        match recent_events with
        | _ :: _ -> `Null
        | [] -> json_string_option (empty_reason ~has_any ?since ?until ()) );
      ("recent_events", `List (List.map pre_compact_event_json recent_events));
      ("total_recent", `Int (List.length events));
    ]

let recent_dna_quality_json ?since ?until ~has_any
    ~(latest : dna_quality_event option) ~(events : dna_quality_event list) () =
  let status = status_to_string (dna_quality_status latest) in
  let recent_events = trim_recent max_runtime_events events in
  `Assoc
    [
      ( "description",
        `String
          "Shows recent continuity DNA quality checks before keeper mitosis or handoff-style spawn flows continue." );
      ("status", `String status);
      ("last_event_at", json_float_option (Option.map dna_quality_timestamp latest));
      ( "empty_reason",
        match recent_events with
        | _ :: _ -> `Null
        | [] -> json_string_option (empty_reason ~has_any ?since ?until ()) );
      ("recent_events", `List (List.map dna_quality_event_json recent_events));
      ("total_recent", `Int (List.length events));
    ]

let json ?since ?until () =
  let calibration = Eval_calibration.calibration_stats ?since ?until () in
  let recent_verdicts = read_recent_verdicts ?since ?until () in
  let has_window = Option.is_some since || Option.is_some until in
  let pre_compact_store = get_pre_compact_store () in
  let pre_compact_events = read_pre_compact_events ?since ?until () in
  let latest_pre_compact : pre_compact_event option =
    if has_window then
      Dated_jsonl.read_recent pre_compact_store 1
      |> List.filter_map pre_compact_event_of_json
      |> latest_by_timestamp pre_compact_timestamp
    else latest_by_timestamp pre_compact_timestamp pre_compact_events
  in
  let pre_compact_has_any =
    if has_window then has_any_records pre_compact_store
    else pre_compact_events <> []
  in
  let dna_quality_store = get_dna_quality_store () in
  let dna_quality_events = read_dna_quality_events ?since ?until () in
  let latest_dna : dna_quality_event option =
    if has_window then
      Dated_jsonl.read_recent dna_quality_store 1
      |> List.filter_map dna_quality_event_of_json
      |> latest_by_timestamp dna_quality_timestamp
    else latest_by_timestamp dna_quality_timestamp dna_quality_events
  in
  let dna_quality_has_any =
    if has_window then has_any_records dna_quality_store
    else dna_quality_events <> []
  in
  `Assoc
    [
      ("generated_at", `Float (Time_compat.now ()));
      ( "scope_note",
        `String
          "Autoresearch tracks the generator loop itself. The safety harness tracks supporting evaluator and long-running continuity rails, so these signals are related but not a direct keep/discard judge for each autoresearch cycle." );
      ( "overview",
        overview_json ~calibration ~recent_verdicts ~latest_pre_compact
          ~latest_dna );
      ("calibration", calibration);
      ("recent_verdicts", `List (List.map verdict_item_json recent_verdicts));
      ( "pre_compact",
        recent_pre_compact_json ?since ?until
          ~has_any:pre_compact_has_any
          ~latest:latest_pre_compact ~events:pre_compact_events () );
      ( "dna_quality",
        recent_dna_quality_json ?since ?until
          ~has_any:dna_quality_has_any ~latest:latest_dna
          ~events:dna_quality_events () );
    ]
