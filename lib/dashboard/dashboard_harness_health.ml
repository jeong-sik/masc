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
  context_window : int;
  is_local_model : bool;
  trigger : string;
}

(** Wake-time payload observation.

    Captured once per keeper turn, just before [Oas_worker.run_named] fires.
    Phase 0 baseline for the tiered-hydration redesign (Option C).
    [approx_body_bytes] is a MASC-side estimate (sum of content text,
    tool definition JSON, system prompt). It is NOT the exact HTTP body
    wire size — provider layers apply further encoding. *)
type wake_payload_event = {
  timestamp : float;
  keeper_name : string;
  trace_id : string;
  turn_index : int;
  model_id : string;
  context_window : int;
  approx_body_bytes : int;
  system_prompt_bytes : int;
  tool_defs_bytes : int;
  messages_bytes : int;
  message_count : int;
  role_counts : (string * int) list;
  tool_count : int;
  has_compact_happened : bool;
}

type handoff_event = {
  timestamp : float;
  keeper_name : string;
  trace_id : string;
  generation : int;
  next_generation : int option;
  prev_trace_id : string option;
  new_trace_id : string option;
  to_model : string option;
}

let max_runtime_events = 12
let max_recent_verdicts = 8
let max_signal_scan = 500
let runtime_stale_after_s = 30. *. 60.
let evaluator_stale_after_s = 12. *. 3600.

(** Runtime health warning thresholds. Distinct from compaction thresholds.
    Values sourced from [Env_config_keeper.DashboardHealth]. *)
let runtime_warning_ctx_ratio = Env_config_keeper.DashboardHealth.runtime_warning_ctx_ratio

let pre_compact_store_ref : Dated_jsonl.t option ref = ref None

(** Store for wake-time payload observations. Populated lazily on first
    [record_wake_payload] call when [MASC_PAYLOAD_TELEMETRY] is enabled. *)
let wake_payload_store_ref : Dated_jsonl.t option ref = ref None

let status_to_string = function
  | Healthy -> "healthy"
  | Warning -> "warning"
  | Stale -> "stale"
  | Idle -> "idle"

let trim_recent (type a) max_items (values : a list) : a list =
  if List.length values <= max_items then values
  else List.filteri (fun idx _ -> idx < max_items) values

let pre_compact_store_base_dir () =
  Filename.concat (Env_config.base_path ()) "data/harness-pre-compact"

let wake_payload_store_base_dir () =
  Filename.concat (Env_config.base_path ()) "data/keeper-wake-payload"

let get_or_create_store store_ref base_dir_fn =
  match !store_ref with
  | Some store -> store
  | None ->
      let store = Dated_jsonl.create ~base_dir:(base_dir_fn ()) () in
      store_ref := Some store;
      store

let get_pre_compact_store () =
  get_or_create_store pre_compact_store_ref pre_compact_store_base_dir

let get_wake_payload_store () =
  get_or_create_store wake_payload_store_ref wake_payload_store_base_dir

let reset_runtime_stores_for_testing () =
  pre_compact_store_ref := None;
  wake_payload_store_ref := None

let set_pre_compact_store_for_testing ~base_dir =
  pre_compact_store_ref := Some (Dated_jsonl.create ~base_dir ())

let set_wake_payload_store_for_testing ~base_dir =
  wake_payload_store_ref := Some (Dated_jsonl.create ~base_dir ())

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
      ("fallback_reason", Json_util.string_opt_to_json item.fallback_reason);
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
      ("context_window", `Int event.context_window);
      ("is_local_model", `Bool event.is_local_model);
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
      ("context_window", `Int event.context_window);
      ("is_local_model", `Bool event.is_local_model);
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
        context_window = Safe_ops.json_int ~default:Cascade_runtime.fallback_context_window "context_window" json;
        is_local_model = Safe_ops.json_bool ~default:false "is_local_model" json;
        trigger = string_field json "trigger";
      }

let role_counts_to_json (counts : (string * int) list) : Yojson.Safe.t =
  `Assoc (List.map (fun (role, n) -> (role, `Int n)) counts)

let role_counts_of_json json : (string * int) list =
  Safe_ops.json_assoc "role_counts" json
  |> List.filter_map (fun (role, value) ->
         match value with
         | `Int n -> Some (role, n)
         | `Intlit s -> (try Some (role, int_of_string s) with _ -> None)
         | _ -> None)

let wake_payload_record_json (event : wake_payload_event) =
  `Assoc
    [
      ("record_type", `String "wake_payload");
      ("timestamp", `Float event.timestamp);
      ("keeper_name", `String event.keeper_name);
      ("trace_id", `String event.trace_id);
      ("turn_index", `Int event.turn_index);
      ("model_id", `String event.model_id);
      ("context_window", `Int event.context_window);
      ("approx_body_bytes", `Int event.approx_body_bytes);
      ("system_prompt_bytes", `Int event.system_prompt_bytes);
      ("tool_defs_bytes", `Int event.tool_defs_bytes);
      ("messages_bytes", `Int event.messages_bytes);
      ("message_count", `Int event.message_count);
      ("role_counts", role_counts_to_json event.role_counts);
      ("tool_count", `Int event.tool_count);
      ("has_compact_happened", `Bool event.has_compact_happened);
    ]

let wake_payload_event_json (event : wake_payload_event) =
  `Assoc
    [
      ("timestamp", `Float event.timestamp);
      ("keeper_name", `String event.keeper_name);
      ("trace_id", `String event.trace_id);
      ("turn_index", `Int event.turn_index);
      ("model_id", `String event.model_id);
      ("context_window", `Int event.context_window);
      ("approx_body_bytes", `Int event.approx_body_bytes);
      ("system_prompt_bytes", `Int event.system_prompt_bytes);
      ("tool_defs_bytes", `Int event.tool_defs_bytes);
      ("messages_bytes", `Int event.messages_bytes);
      ("message_count", `Int event.message_count);
      ("role_counts", role_counts_to_json event.role_counts);
      ("tool_count", `Int event.tool_count);
      ("has_compact_happened", `Bool event.has_compact_happened);
    ]

let wake_payload_event_of_json json =
  let record_type = string_field json "record_type" in
  if record_type <> "" && not (String.equal record_type "wake_payload") then None
  else
    Some
      {
        timestamp = Safe_ops.json_float ~default:0.0 "timestamp" json;
        keeper_name = string_field json "keeper_name";
        trace_id = string_field json "trace_id";
        turn_index = Safe_ops.json_int ~default:0 "turn_index" json;
        model_id = string_field json "model_id";
        context_window =
          Safe_ops.json_int
            ~default:Cascade_runtime.fallback_context_window
            "context_window" json;
        approx_body_bytes = Safe_ops.json_int ~default:0 "approx_body_bytes" json;
        system_prompt_bytes = Safe_ops.json_int ~default:0 "system_prompt_bytes" json;
        tool_defs_bytes = Safe_ops.json_int ~default:0 "tool_defs_bytes" json;
        messages_bytes = Safe_ops.json_int ~default:0 "messages_bytes" json;
        message_count = Safe_ops.json_int ~default:0 "message_count" json;
        role_counts = role_counts_of_json json;
        tool_count = Safe_ops.json_int ~default:0 "tool_count" json;
        has_compact_happened =
          Safe_ops.json_bool ~default:false "has_compact_happened" json;
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

let read_recent_verdicts_for_agents
    ?since ?until ?(limit = max_recent_verdicts) ~agent_names ()
    : harness_verdict_item list =
  let wanted =
    agent_names
    |> List.map String.trim
    |> List.filter (fun name -> name <> "")
  in
  if wanted = [] then []
  else
    let is_wanted name = List.exists (String.equal name) wanted in
    let records = read_store_records (Eval_calibration.get_store ()) ?since ?until () in
    let verdicts : harness_verdict_item list =
      records
      |> List.filter_map verdict_item_of_json
      |> List.filter (fun verdict -> is_wanted verdict.agent_name)
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

let read_wake_payload_events ?since ?until () =
  let records = read_store_records (get_wake_payload_store ()) ?since ?until () in
  let events : wake_payload_event list =
    records |> List.filter_map wake_payload_event_of_json
  in
  List.sort
    (fun (left : wake_payload_event) (right : wake_payload_event) ->
      Float.compare right.timestamp left.timestamp)
    events

let handoff_event_of_metrics_json json =
  let handoff =
    match Safe_ops.json_member_opt "handoff" json with
    | Some value -> value
    | None -> `Assoc []
  in
  if not (Safe_ops.json_bool ~default:false "performed" handoff) then None
  else
    let next_generation =
      match Safe_ops.json_int_opt "to_generation" handoff with
      | Some value -> Some value
      | None -> Safe_ops.json_int_opt "new_generation" handoff
    in
    Some
      {
        timestamp = Safe_ops.json_float ~default:0.0 "ts_unix" json;
        keeper_name = string_field json "name";
        trace_id = string_field json "trace_id";
        generation = Safe_ops.json_int ~default:0 "generation" json;
        next_generation;
        prev_trace_id = Safe_ops.json_string_opt "prev_trace_id" handoff;
        new_trace_id = Safe_ops.json_string_opt "new_trace_id" handoff;
        to_model = Safe_ops.json_string_opt "to_model" handoff;
      }

let handoff_event_json (event : handoff_event) =
  `Assoc
    [
      ("timestamp", `Float event.timestamp);
      ("keeper_name", `String event.keeper_name);
      ("trace_id", `String event.trace_id);
      ("generation", `Int event.generation);
      ("next_generation", Json_util.int_opt_to_json event.next_generation);
      ("prev_trace_id", Json_util.string_opt_to_json event.prev_trace_id);
      ("new_trace_id", Json_util.string_opt_to_json event.new_trace_id);
      ("to_model", Json_util.string_opt_to_json event.to_model);
    ]

let read_keeper_metric_records ?since ?until (config : Coord.config) keeper_name =
  let store = Keeper_types.keeper_metrics_store config keeper_name in
  match (since, until) with
  | Some _, _ | _, Some _ ->
      let since, until = date_bounds ?since ?until () in
      let start_date = if since = "" then "2020-01-01" else since in
      let end_date = if until = "" then "2099-12-31" else until in
      Dated_jsonl.read_range store ~since:start_date ~until:end_date
  | None, None -> Dated_jsonl.read_recent store max_signal_scan

let read_handoff_events ?since ?until (config : Coord.config) =
  let events =
    Keeper_types.keeper_names config
    |> List.concat_map (fun keeper_name ->
           read_keeper_metric_records ?since ?until config keeper_name
           |> List.filter_map handoff_event_of_metrics_json)
  in
  List.sort
    (fun (left : handoff_event) (right : handoff_event) ->
      Float.compare right.timestamp left.timestamp)
    events

let has_any_handoff_events (config : Coord.config) =
  Keeper_types.keeper_names config
  |> List.exists (fun keeper_name ->
         read_keeper_metric_records config keeper_name
         |> List.exists (fun json ->
                Option.is_some (handoff_event_of_metrics_json json)))

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
      (* Boundary: use ratio-based check only. Raw token_count is an OAS
         infrastructure concern — MASC operates on abstract ratio (0.0–1.0).
         The context_ratio threshold already accounts for model-specific
         context windows, making absolute token thresholds redundant. *)
      else if event.context_ratio >= runtime_warning_ctx_ratio then Warning
      else Healthy

let handoff_status (latest_event : handoff_event option) =
  match latest_event with
  | None -> Idle
  | Some event ->
      if is_stale ~threshold_s:runtime_stale_after_s event.timestamp then Stale
      else if
        Option.is_none event.prev_trace_id
        || Option.is_none event.new_trace_id
        || Option.is_none event.next_generation
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
let handoff_timestamp (event : handoff_event) = event.timestamp
let handoff_generation (event : handoff_event) = event.next_generation

let overview_json
    ~(calibration : Yojson.Safe.t)
    ~(recent_verdicts : harness_verdict_item list)
    ~(latest_pre_compact : pre_compact_event option)
    ~(latest_handoff : handoff_event option) =
  let verdict_last = latest_timestamp_of_verdicts recent_verdicts in
  let pre_compact_last = Option.map pre_compact_timestamp latest_pre_compact in
  let handoff_last = Option.map handoff_timestamp latest_handoff in
  let fallback_count = Safe_ops.json_int ~default:0 "fallback_count" calibration in
  let total_verdicts = Safe_ops.json_int ~default:0 "total_verdicts" calibration in
  let fallback_ratio =
    if total_verdicts = 0 then 0.0
    else float_of_int fallback_count /. float_of_int total_verdicts
  in
  (* Cross-model enforcement ratio: of verdicts that recorded both a
     generator and an evaluator cascade, what fraction used distinct
     cascades? This is the *runtime* rate at which the cross-model
     review policy (anti_rationalization.mli, #3067) actually fired. *)
  let verdicts_with_generator =
    Safe_ops.json_int ~default:0 "verdicts_with_generator_cascade" calibration
  in
  let cross_model_match =
    Safe_ops.json_int ~default:0 "cross_model_match_count" calibration
  in
  let cross_model_rate =
    if verdicts_with_generator = 0 then 0.0
    else float_of_int cross_model_match /. float_of_int verdicts_with_generator
  in
  let last_signal_at =
    max_timestamp verdict_last (max_timestamp pre_compact_last handoff_last)
  in
  `Assoc
    [
      ( "evaluator_status",
        `String (status_to_string (evaluator_status ~calibration verdict_last)) );
      ( "pre_compact_status",
        `String (status_to_string (pre_compact_status latest_pre_compact)) );
      ("handoff_status", `String (status_to_string (handoff_status latest_handoff)));
      ("last_signal_at", Json_util.float_opt_to_json last_signal_at);
      ("evaluator_last_event_at", Json_util.float_opt_to_json verdict_last);
      ("pre_compact_last_event_at", Json_util.float_opt_to_json pre_compact_last);
      ("handoff_last_event_at", Json_util.float_opt_to_json handoff_last);
      ("fallback_ratio", `Float fallback_ratio);
      ("cross_model_rate", `Float cross_model_rate);
      ("cross_model_match_count", `Int cross_model_match);
      ("verdicts_with_generator_cascade", `Int verdicts_with_generator);
      ( "latest_pre_compact_ratio",
        Json_util.float_opt_to_json (Option.map pre_compact_ratio latest_pre_compact) );
      ( "latest_handoff_generation",
        Json_util.int_opt_to_json (Option.bind latest_handoff handoff_generation) );
    ]

let record_pre_compact_at ~timestamp ~keeper_name ~context_ratio ~message_count
    ~token_count ~strategies ~context_window ~is_local_model ~trigger =
  let event =
    {
      timestamp;
      keeper_name;
      context_ratio;
      message_count;
      token_count;
      strategies;
      context_window;
      is_local_model;
      trigger;
    }
  in
  Dated_jsonl.append (get_pre_compact_store ()) (pre_compact_record_json event);
  event

let record_pre_compact ~keeper_name ~context_ratio ~message_count ~token_count
    ~strategies ~context_window ~is_local_model ~trigger =
  record_pre_compact_at ~timestamp:(Time_compat.now ()) ~keeper_name
    ~context_ratio ~message_count ~token_count ~strategies ~context_window
    ~is_local_model ~trigger

let record_wake_payload_at ~timestamp ~keeper_name ~trace_id ~turn_index
    ~model_id ~context_window ~approx_body_bytes ~system_prompt_bytes
    ~tool_defs_bytes ~messages_bytes ~message_count ~role_counts ~tool_count
    ~has_compact_happened =
  let event =
    {
      timestamp;
      keeper_name;
      trace_id;
      turn_index;
      model_id;
      context_window;
      approx_body_bytes;
      system_prompt_bytes;
      tool_defs_bytes;
      messages_bytes;
      message_count;
      role_counts;
      tool_count;
      has_compact_happened;
    }
  in
  Dated_jsonl.append (get_wake_payload_store ())
    (wake_payload_record_json event);
  event

let record_wake_payload ~keeper_name ~trace_id ~turn_index ~model_id
    ~context_window ~approx_body_bytes ~system_prompt_bytes ~tool_defs_bytes
    ~messages_bytes ~message_count ~role_counts ~tool_count
    ~has_compact_happened =
  record_wake_payload_at ~timestamp:(Time_compat.now ()) ~keeper_name
    ~trace_id ~turn_index ~model_id ~context_window ~approx_body_bytes
    ~system_prompt_bytes ~tool_defs_bytes ~messages_bytes ~message_count
    ~role_counts ~tool_count ~has_compact_happened

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
      ("last_event_at", Json_util.float_opt_to_json (Option.map pre_compact_timestamp latest));
      ( "empty_reason",
        match recent_events with
        | _ :: _ -> `Null
        | [] -> Json_util.string_opt_to_json (empty_reason ~has_any ?since ?until ()) );
      ("recent_events", `List (List.map pre_compact_event_json recent_events));
      ("total_recent", `Int (List.length events));
    ]

let recent_handoffs_json ?since ?until ~has_any
    ~(latest : handoff_event option) ~(events : handoff_event list) () =
  let status = status_to_string (handoff_status latest) in
  let recent_events = trim_recent max_runtime_events events in
  `Assoc
    [
      ( "description",
        `String
          "Shows recent keeper checkpoint rollovers sourced from keeper metrics snapshots." );
      ("status", `String status);
      ("last_event_at", Json_util.float_opt_to_json (Option.map handoff_timestamp latest));
      ( "empty_reason",
        match recent_events with
        | _ :: _ -> `Null
        | [] -> Json_util.string_opt_to_json (empty_reason ~has_any ?since ?until ()) );
      ("recent_events", `List (List.map handoff_event_json recent_events));
      ("total_recent", `Int (List.length events));
    ]

let json ~(config : Coord.config) ?since ?until () =
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
  let handoff_events = read_handoff_events ?since ?until config in
  let latest_handoff : handoff_event option =
    latest_by_timestamp handoff_timestamp handoff_events
  in
  let handoff_has_any =
    match handoff_events with
    | _ :: _ -> true
    | [] when has_window -> has_any_handoff_events config
    | [] -> false
  in
  `Assoc
    [
      ("generated_at", `Float (Time_compat.now ()));
      ( "scope_note",
        `String
          "Autoresearch tracks the generator loop itself. The safety harness tracks supporting evaluator and long-running continuity rails, so these signals are related but not a direct keep/discard judge for each autoresearch cycle." );
      ( "overview",
        overview_json ~calibration ~recent_verdicts ~latest_pre_compact
          ~latest_handoff );
      ("calibration", calibration);
      ("recent_verdicts", `List (List.map verdict_item_json recent_verdicts));
      ( "pre_compact",
        recent_pre_compact_json ?since ?until
          ~has_any:pre_compact_has_any
          ~latest:latest_pre_compact ~events:pre_compact_events () );
      ( "recent_handoffs",
        recent_handoffs_json ?since ?until
          ~has_any:handoff_has_any ~latest:latest_handoff
          ~events:handoff_events () );
    ]
