(** Keeper_exec_status — shared keeper status, metrics, and diagnostic helpers. *)

open Keeper_types

type metrics_summary = {
  sample_points : int;
  turn_points : int;
  heartbeat_points : int;
  proactive_points : int;
  auto_reflect_count : int;
  auto_plan_count : int;
  auto_compact_count : int;
  auto_handoff_count : int;
  guardrail_stop_count : int;
  drift_applied_count : int;
  handoff_count : int;
  compaction_events : int;
  compaction_saved_tokens : int;
  memory_compaction_events : int;
  memory_compaction_before_notes : int;
  memory_compaction_dropped_notes : int;
  memory_compaction_invalid_dropped : int;
  memory_checks : int;
  memory_passed : int;
  memory_failed : int;
  memory_correction_applied : int;
  memory_correction_success : int;
  memory_score_sum : float;
  memory_weather_checks : int;
  memory_weather_passed : int;
  repetition_risk_sum : float;
  repetition_risk_points : int;
  goal_alignment_sum : float;
  goal_alignment_points : int;
  response_alignment_sum : float;
  response_alignment_points : int;
  goal_drift_sum : float;
  goal_drift_points : int;
  last_handoff : Yojson.Safe.t option;
  last_compaction : Yojson.Safe.t option;
}

let empty_metrics_summary =
  {
    sample_points = 0;
    turn_points = 0;
    heartbeat_points = 0;
    proactive_points = 0;
    auto_reflect_count = 0;
    auto_plan_count = 0;
    auto_compact_count = 0;
    auto_handoff_count = 0;
    guardrail_stop_count = 0;
    drift_applied_count = 0;
    handoff_count = 0;
    compaction_events = 0;
    compaction_saved_tokens = 0;
    memory_compaction_events = 0;
    memory_compaction_before_notes = 0;
    memory_compaction_dropped_notes = 0;
    memory_compaction_invalid_dropped = 0;
    memory_checks = 0;
    memory_passed = 0;
    memory_failed = 0;
    memory_correction_applied = 0;
    memory_correction_success = 0;
    memory_score_sum = 0.0;
    memory_weather_checks = 0;
    memory_weather_passed = 0;
    repetition_risk_sum = 0.0;
    repetition_risk_points = 0;
    goal_alignment_sum = 0.0;
    goal_alignment_points = 0;
    response_alignment_sum = 0.0;
    response_alignment_points = 0;
    goal_drift_sum = 0.0;
    goal_drift_points = 0;
    last_handoff = None;
    last_compaction = None;
  }

let metrics_summary_to_json (s : metrics_summary) : Yojson.Safe.t =
  let interaction_points = s.turn_points + s.proactive_points in
  let intervention_share =
    if interaction_points = 0 then 0.0
    else float_of_int s.proactive_points /. float_of_int interaction_points
  in
  let intervention_per_turn =
    if s.turn_points = 0 then 0.0
    else float_of_int s.proactive_points /. float_of_int s.turn_points
  in
  let drift_applied_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.drift_applied_count /. float_of_int interaction_points
  in
  let auto_reflect_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.auto_reflect_count /. float_of_int interaction_points
  in
  let auto_plan_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.auto_plan_count /. float_of_int interaction_points
  in
  let auto_compact_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.auto_compact_count /. float_of_int interaction_points
  in
  let auto_handoff_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.auto_handoff_count /. float_of_int interaction_points
  in
  let guardrail_stop_rate =
    if interaction_points = 0 then 0.0
    else float_of_int s.guardrail_stop_count /. float_of_int interaction_points
  in
  let memory_pass_rate =
    if s.memory_checks = 0 then 0.0
    else float_of_int s.memory_passed /. float_of_int s.memory_checks
  in
  let memory_avg_score =
    if s.memory_checks = 0 then 0.0
    else s.memory_score_sum /. float_of_int s.memory_checks
  in
  let memory_weather_pass_rate =
    if s.memory_weather_checks = 0 then 0.0
    else float_of_int s.memory_weather_passed /. float_of_int s.memory_weather_checks
  in
  let memory_compaction_drop_ratio =
    if s.memory_compaction_before_notes = 0 then 0.0
    else
      float_of_int s.memory_compaction_dropped_notes
      /. float_of_int s.memory_compaction_before_notes
  in
  let memory_compaction_drop_avg =
    if s.memory_compaction_events = 0 then 0.0
    else
      float_of_int s.memory_compaction_dropped_notes
      /. float_of_int s.memory_compaction_events
  in
  let repetition_risk_avg =
    if s.repetition_risk_points = 0 then 0.0
    else s.repetition_risk_sum /. float_of_int s.repetition_risk_points
  in
  let goal_alignment_avg =
    if s.goal_alignment_points = 0 then 0.0
    else s.goal_alignment_sum /. float_of_int s.goal_alignment_points
  in
  let response_alignment_avg =
    if s.response_alignment_points = 0 then 0.0
    else s.response_alignment_sum /. float_of_int s.response_alignment_points
  in
  let goal_drift_avg =
    if s.goal_drift_points = 0 then 0.0
    else s.goal_drift_sum /. float_of_int s.goal_drift_points
  in
  `Assoc
    [
      ("sample_points", `Int s.sample_points);
      ("turn_points", `Int s.turn_points);
      ("heartbeat_points", `Int s.heartbeat_points);
      ("proactive_points", `Int s.proactive_points);
      ("window_interactions", `Int interaction_points);
      ("intervention_share", `Float intervention_share);
      ("intervention_per_turn", `Float intervention_per_turn);
      ("auto_reflect_count", `Int s.auto_reflect_count);
      ("auto_plan_count", `Int s.auto_plan_count);
      ("auto_compact_count", `Int s.auto_compact_count);
      ("auto_handoff_count", `Int s.auto_handoff_count);
      ("guardrail_stop_count", `Int s.guardrail_stop_count);
      ("auto_reflect_rate", `Float auto_reflect_rate);
      ("auto_plan_rate", `Float auto_plan_rate);
      ("auto_compact_rate", `Float auto_compact_rate);
      ("auto_handoff_rate", `Float auto_handoff_rate);
      ("guardrail_stop_rate", `Float guardrail_stop_rate);
      ("drift_applied_count", `Int s.drift_applied_count);
      ("drift_applied_rate", `Float drift_applied_rate);
      ("handoff_count", `Int s.handoff_count);
      ("compaction_events", `Int s.compaction_events);
      ("compaction_saved_tokens", `Int s.compaction_saved_tokens);
      ("memory_compaction_events", `Int s.memory_compaction_events);
      ("memory_compaction_before_notes", `Int s.memory_compaction_before_notes);
      ("memory_compaction_dropped_notes", `Int s.memory_compaction_dropped_notes);
      ("memory_compaction_invalid_dropped", `Int s.memory_compaction_invalid_dropped);
      ("memory_compaction_drop_ratio", `Float memory_compaction_drop_ratio);
      ("memory_compaction_drop_avg", `Float memory_compaction_drop_avg);
      ("memory_checks", `Int s.memory_checks);
      ("memory_passed", `Int s.memory_passed);
      ("memory_failed", `Int s.memory_failed);
      ("memory_pass_rate", `Float memory_pass_rate);
      ("memory_avg_score", `Float memory_avg_score);
      ("memory_correction_applied", `Int s.memory_correction_applied);
      ("memory_correction_success", `Int s.memory_correction_success);
      ("memory_weather_checks", `Int s.memory_weather_checks);
      ("memory_weather_passed", `Int s.memory_weather_passed);
      ("memory_weather_pass_rate", `Float memory_weather_pass_rate);
      ("repetition_risk_avg", `Float repetition_risk_avg);
      ("goal_alignment_avg", `Float goal_alignment_avg);
      ("response_alignment_avg", `Float response_alignment_avg);
      ("goal_drift_avg", `Float goal_drift_avg);
      ("last_handoff", match s.last_handoff with Some j -> j | None -> `Null);
      ("last_compaction", match s.last_compaction with Some j -> j | None -> `Null);
    ]

let summarize_metrics_lines (lines : string list) ~(default_generation : int) :
    metrics_summary =
  let open Yojson.Safe.Util in
  List.fold_left
    (fun acc line ->
      try
        let j = Yojson.Safe.from_string line in
        let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
        let trace_id = Safe_ops.json_string ~default:"" "trace_id" j in
        let generation =
          Safe_ops.json_int ~default:default_generation "generation" j
        in
        let channel = Safe_ops.json_string ~default:"turn" "channel" j in
        let is_turn = channel = "turn" in
        let is_heartbeat = channel = "heartbeat" in
        let is_proactive = channel = "proactive" in
        let is_interaction = is_turn || is_proactive in
        let compacted = Safe_ops.json_bool ~default:false "compacted" j in
        let before_tokens =
          Safe_ops.json_int ~default:0 "compaction_before_tokens" j
        in
        let after_tokens =
          Safe_ops.json_int ~default:0 "compaction_after_tokens" j
        in
        let saved_tokens = max 0 (before_tokens - after_tokens) in
        let handoff = j |> member "handoff" in
        let handoff_performed =
          Safe_ops.json_bool ~default:false "performed" handoff
        in
        let to_model = Safe_ops.json_string_opt "to_model" handoff in
        let prev_trace_id = Safe_ops.json_string_opt "prev_trace_id" handoff in
        let new_trace_id = Safe_ops.json_string_opt "new_trace_id" handoff in
        let memory = j |> member "memory_check" in
        let memory_performed =
          Safe_ops.json_bool ~default:false "performed" memory
        in
        let memory_passed =
          Safe_ops.json_bool ~default:false "passed" memory
        in
        let memory_final_score =
          Safe_ops.json_float ~default:0.0 "final_score" memory
        in
        let memory_correction_applied =
          Safe_ops.json_bool ~default:false "correction_applied" memory
        in
        let memory_correction_success =
          Safe_ops.json_bool ~default:false "correction_success" memory
        in
        let memory_expected_topic =
          Safe_ops.json_string_opt "expected_topic" memory
        in
        let memory_compaction_performed =
          Safe_ops.json_bool ~default:false "memory_compaction_performed" j
        in
        let memory_compaction_before_now =
          Safe_ops.json_int ~default:0 "memory_compaction_before_notes" j
        in
        let memory_compaction_dropped_now =
          Safe_ops.json_int ~default:0 "memory_compaction_dropped_notes" j
        in
        let memory_compaction_invalid_now =
          Safe_ops.json_int ~default:0 "memory_compaction_invalid_dropped" j
        in
        let drift = j |> member "drift" in
        let drift_applied_now =
          Safe_ops.json_bool ~default:false "applied" drift
        in
        let memory_is_weather =
          match memory_expected_topic with Some "weather" -> true | _ -> false
        in
        let auto_rules = j |> member "auto_rules" in
        let auto_reflect_now =
          Safe_ops.json_bool
            ~default:(Safe_ops.json_bool ~default:false "reflect" auto_rules)
            "auto_reflect" j
        in
        let auto_plan_now =
          Safe_ops.json_bool
            ~default:(Safe_ops.json_bool ~default:false "plan" auto_rules)
            "auto_plan" j
        in
        let auto_compact_now =
          Safe_ops.json_bool
            ~default:(Safe_ops.json_bool ~default:false "compact" auto_rules)
            "auto_compact" j
        in
        let auto_handoff_now =
          Safe_ops.json_bool
            ~default:(Safe_ops.json_bool ~default:false "handoff" auto_rules)
            "auto_handoff" j
        in
        let guardrail_stop_now =
          Safe_ops.json_bool
            ~default:(Safe_ops.json_bool ~default:false "guardrail_stop" auto_rules)
            "guardrail_stop" j
        in
        let repetition_risk_opt = Safe_ops.json_float_opt "repetition_risk" j in
        let goal_alignment_opt = Safe_ops.json_float_opt "goal_alignment" j in
        let response_alignment_opt = Safe_ops.json_float_opt "response_alignment" j in
        let goal_drift_opt = Safe_ops.json_float_opt "goal_drift" j in
        let handoff_json =
          if handoff_performed then
            Some
              (`Assoc
                [
                  ("ts_unix", `Float ts_unix);
                  ("trace_id", `String trace_id);
                  ("generation", `Int generation);
                  ( "to_model",
                    match to_model with Some s when s <> "" -> `String s | _ -> `Null );
                  ( "prev_trace_id",
                    match prev_trace_id with Some s when s <> "" -> `String s | _ -> `Null );
                  ( "new_trace_id",
                    match new_trace_id with Some s when s <> "" -> `String s | _ -> `Null );
                ])
          else acc.last_handoff
        in
        let compaction_json =
          if compacted then
            let trigger = Safe_ops.json_string_opt "compaction_trigger" j in
            Some
              (`Assoc
                [
                  ("ts_unix", `Float ts_unix);
                  ("trace_id", `String trace_id);
                  ("generation", `Int generation);
                  ("before_tokens", `Int before_tokens);
                  ("after_tokens", `Int after_tokens);
                  ("saved_tokens", `Int saved_tokens);
                  ( "trigger",
                    match trigger with
                    | Some reason when String.trim reason <> "" -> `String reason
                    | _ -> `Null );
                ])
          else acc.last_compaction
        in
        {
          sample_points = acc.sample_points + 1;
          turn_points = acc.turn_points + (if is_turn then 1 else 0);
          heartbeat_points = acc.heartbeat_points + (if is_heartbeat then 1 else 0);
          proactive_points = acc.proactive_points + (if is_proactive then 1 else 0);
          auto_reflect_count =
            acc.auto_reflect_count + (if is_interaction && auto_reflect_now then 1 else 0);
          auto_plan_count =
            acc.auto_plan_count + (if is_interaction && auto_plan_now then 1 else 0);
          auto_compact_count =
            acc.auto_compact_count + (if is_interaction && auto_compact_now then 1 else 0);
          auto_handoff_count =
            acc.auto_handoff_count + (if is_interaction && auto_handoff_now then 1 else 0);
          guardrail_stop_count =
            acc.guardrail_stop_count + (if is_interaction && guardrail_stop_now then 1 else 0);
          drift_applied_count =
            acc.drift_applied_count + (if is_interaction && drift_applied_now then 1 else 0);
          handoff_count =
            acc.handoff_count + (if is_interaction && handoff_performed then 1 else 0);
          compaction_events =
            acc.compaction_events + (if is_interaction && compacted then 1 else 0);
          compaction_saved_tokens =
            acc.compaction_saved_tokens
            + (if is_interaction && compacted then saved_tokens else 0);
          memory_compaction_events =
            acc.memory_compaction_events
            + (if is_interaction && memory_compaction_performed then 1 else 0);
          memory_compaction_before_notes =
            acc.memory_compaction_before_notes
            + (if is_interaction && memory_compaction_performed then memory_compaction_before_now else 0);
          memory_compaction_dropped_notes =
            acc.memory_compaction_dropped_notes
            + (if is_interaction && memory_compaction_performed then memory_compaction_dropped_now else 0);
          memory_compaction_invalid_dropped =
            acc.memory_compaction_invalid_dropped
            + (if is_interaction && memory_compaction_performed then memory_compaction_invalid_now else 0);
          memory_checks =
            acc.memory_checks + (if is_interaction && memory_performed then 1 else 0);
          memory_passed =
            acc.memory_passed
            + (if is_interaction && memory_performed && memory_passed then 1 else 0);
          memory_failed =
            acc.memory_failed
            + (if is_interaction && memory_performed && not memory_passed then 1 else 0);
          memory_correction_applied =
            acc.memory_correction_applied
            + (if is_interaction && memory_performed && memory_correction_applied then 1 else 0);
          memory_correction_success =
            acc.memory_correction_success
            + (if is_interaction && memory_performed && memory_correction_success then 1 else 0);
          memory_score_sum =
            acc.memory_score_sum
            +. (if is_interaction && memory_performed then memory_final_score else 0.0);
          memory_weather_checks =
            acc.memory_weather_checks
            + (if is_interaction && memory_performed && memory_is_weather then 1 else 0);
          memory_weather_passed =
            acc.memory_weather_passed
            + (if is_interaction && memory_performed && memory_is_weather && memory_passed then 1 else 0);
          repetition_risk_sum =
            acc.repetition_risk_sum
            +. (match repetition_risk_opt with Some v -> v | None -> 0.0);
          repetition_risk_points =
            acc.repetition_risk_points + (if Option.is_some repetition_risk_opt then 1 else 0);
          goal_alignment_sum =
            acc.goal_alignment_sum
            +. (match goal_alignment_opt with Some v -> v | None -> 0.0);
          goal_alignment_points =
            acc.goal_alignment_points + (if Option.is_some goal_alignment_opt then 1 else 0);
          response_alignment_sum =
            acc.response_alignment_sum
            +. (if is_interaction then Option.value ~default:0.0 response_alignment_opt else 0.0);
          response_alignment_points =
            acc.response_alignment_points
            + (if is_interaction && Option.is_some response_alignment_opt then 1 else 0);
          goal_drift_sum =
            acc.goal_drift_sum
            +. (if is_interaction then Option.value ~default:0.0 goal_drift_opt else 0.0);
          goal_drift_points =
            acc.goal_drift_points
            + (if is_interaction && Option.is_some goal_drift_opt then 1 else 0);
          last_handoff = handoff_json;
          last_compaction = compaction_json;
        }
      with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> acc)
    empty_metrics_summary lines

let active_model_of_meta (m : keeper_meta) : string =
  if String.trim m.active_model <> "" then m.active_model
  else if m.last_model_used <> "" then m.last_model_used
  else
    match m.allowed_models @ m.models with
    | model :: _ -> model
    | [] -> ""

let next_model_hint_of_meta (m : keeper_meta) : string option =
  let active = active_model_of_meta m in
  let pool = dedupe_keep_order (m.allowed_models @ m.models) in
  match List.filter (fun model -> model <> active) pool with
  | next_model :: _ -> Some next_model
  | [] -> (
      match pool with
      | current :: _ -> Some current
      | [] -> None)

let parse_agent_status (config : Room.config) ~(agent_name : string) : Yojson.Safe.t =
  let agent_file =
    Filename.concat (Room.agents_dir config) (Room.safe_filename agent_name ^ ".json")
  in
  if not (Sys.file_exists agent_file) then
    `Assoc [ ("exists", `Bool false) ]
  else
    match Safe_ops.read_json_file_safe agent_file with
    | Error _ ->
        `Assoc [ ("exists", `Bool true); ("error", `String "failed_to_read") ]
    | Ok json -> (
        match Types.agent_of_yojson json with
        | Error _ ->
            `Assoc [ ("exists", `Bool true); ("error", `String "failed_to_parse") ]
        | Ok (agent : Types.agent) ->
            let now_ts = Time_compat.now () in
            let joined_ts =
              Resilience.Time.parse_iso8601_opt agent.joined_at
              |> Option.value ~default:0.0
            in
            let last_seen_ts =
              Resilience.Time.parse_iso8601_opt agent.last_seen
              |> Option.value ~default:0.0
            in
            let age_s = if joined_ts <= 0.0 then 0.0 else now_ts -. joined_ts in
            let last_seen_ago_s =
              if last_seen_ts <= 0.0 then 0.0 else now_ts -. last_seen_ts
            in
            `Assoc
              [
                ("exists", `Bool true);
                ("name", `String agent.name);
                ("agent_type", `String agent.agent_type);
                ("status", `String (Types.string_of_agent_status agent.status));
                ( "capabilities",
                  `List (List.map (fun s -> `String s) agent.capabilities) );
                ( "current_task",
                  match agent.current_task with None -> `Null | Some t -> `String t );
                ("joined_at", `String agent.joined_at);
                ("last_seen", `String agent.last_seen);
                ("age_s", `Float age_s);
                ("last_seen_ago_s", `Float last_seen_ago_s);
                ("is_zombie", `Bool (Room.is_zombie_agent ~agent_name:agent.name agent.last_seen));
              ])

let json_string_opt key json =
  match Yojson.Safe.Util.member key json with
  | `String s ->
      let trimmed = String.trim s in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let json_bool key json default =
  match Yojson.Safe.Util.member key json with
  | `Bool value -> value
  | _ -> default

let json_float_opt key json =
  match Yojson.Safe.Util.member key json with
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | _ -> None

let string_contains_ci haystack needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop idx =
    if idx + nlen > hlen then false
    else if String.sub haystack idx nlen = needle then true
    else loop (idx + 1)
  in
  needle <> "" && loop 0

let quiet_hours_active () =
  let current_hour =
    let tm = Unix.gmtime (Time_compat.now ()) in
    (* KST = UTC+9; must use gmtime, not localtime *)
    (tm.Unix.tm_hour + 9) mod 24
  in
  let quiet_start = Env_config.LodgeV2.quiet_start in
  let quiet_end = Env_config.LodgeV2.quiet_end in
  quiet_start < quiet_end
  && current_hour >= quiet_start
  && current_hour < quiet_end

let keeper_reply_snapshot_of_history (history_items : Yojson.Safe.t list) =
  let open Yojson.Safe.Util in
  let normalize_content item =
    match json_string_opt "content" item with
    | Some value -> value
    | None -> Option.value ~default:"" (json_string_opt "preview" item)
  in
  let update_last role ts content ((last_user, last_assistant) as acc) =
    let role = String.lowercase_ascii role in
    if role = "user" then
      (Some (ts, content), last_assistant)
    else if role = "assistant" then
      (last_user, Some (ts, content))
    else acc
  in
  let last_user, last_assistant =
    List.fold_left
      (fun acc item ->
        match item with
        | `Assoc _ ->
            let role = item |> member "role" |> to_string_option in
            let ts_unix =
              match json_float_opt "ts_unix" item with
              | Some ts when ts > 0.0 -> Some ts
              | _ -> json_float_opt "timestamp" item
            in
            let content = normalize_content item in
            (match role, ts_unix with
            | Some role, Some ts -> update_last role ts content acc
            | _ -> acc)
        | _ -> acc)
      (None, None) history_items
  in
  match last_user, last_assistant with
  | None, None -> (`String "never", `Null, `Null)
  | Some (user_ts, _), Some (assistant_ts, preview) when assistant_ts >= user_ts ->
      (`String "delivered", `Float assistant_ts, `String preview)
  | Some _, Some (assistant_ts, preview) ->
      (`String "delivered", `Float assistant_ts, `String preview)
  | Some _, None -> (`String "awaiting_reply", `Null, `Null)
  | None, Some (assistant_ts, preview) ->
      (`String "delivered", `Float assistant_ts, `String preview)

let keeper_error_hint ~agent_status ~meta =
  let agent_error = json_string_opt "error" agent_status in
  let proactive_reason =
    let reason = String.trim meta.last_proactive_reason in
    if reason = "" then None else Some reason
  in
  let drift_reason =
    let reason = String.trim meta.last_drift_reason in
    if reason = "" then None else Some reason
  in
  let looks_error_like text =
    List.exists (string_contains_ci text)
      [
        "error";
        "failed";
        "timeout";
        "graphql";
        "model";
        "ollama";
        "gemini";
        "openai";
      ]
  in
  match agent_error with
  | Some _ as error -> error
  | None -> (
      match proactive_reason with
      | Some reason when looks_error_like reason -> Some reason
      | _ -> (
          match drift_reason with
          | Some reason when looks_error_like reason -> Some reason
          | _ -> None))

let classify_keeper_quiet_reason ~meta ~keepalive_running ~agent_status ~now_ts =
  let quiet_active = quiet_hours_active () in
  let agent_exists = json_bool "exists" agent_status false in
  let agent_status_text =
    json_string_opt "status" agent_status
    |> Option.value ~default:"unknown"
    |> String.lowercase_ascii
  in
  let error_hint = keeper_error_hint ~agent_status ~meta in
  if
    not keepalive_running
    || not agent_exists
    || agent_status_text = "offline"
    || agent_status_text = "inactive"
  then Some "disabled"
  else if meta.total_turns = 0 && meta.proactive_count_total = 0 then
    let keeper_age_s =
      match Resilience.Time.parse_iso8601_opt meta.created_at with
      | Some created_ts when created_ts > 0.0 -> max 0.0 (now_ts -. created_ts)
      | _ -> 0.0
    in
    if keeper_age_s <= 120.0 then Some "startup" else Some "never_started"
  else if quiet_active then
    Some "quiet_hours"
  else
    match error_hint with
    | Some reason when string_contains_ci reason "graphql" -> Some "graphql_error"
    | Some reason
      when
        List.exists (string_contains_ci reason)
          [ "model"; "timeout"; "ollama"; "gemini"; "openai" ]
      ->
        Some "model_error"
    | Some _ -> Some "unknown"
    | None ->
        let last_turn_ago_s =
          if meta.last_turn_ts <= 0.0 then None
          else Some (max 0.0 (now_ts -. meta.last_turn_ts))
        in
        let last_proactive_ago_s =
          if meta.last_proactive_ts <= 0.0 then None
          else Some (max 0.0 (now_ts -. meta.last_proactive_ts))
        in
        if meta.proactive_enabled then
          match last_proactive_ago_s with
          | Some age when age < float_of_int meta.proactive_cooldown_sec ->
              Some "min_gap"
          | _ -> (
              match last_turn_ago_s with
              | Some age when age < float_of_int meta.proactive_idle_sec ->
                  Some "no_recent_activity"
              | _ -> None)
        else None

let keeper_health_state ?(fiber_health = Fiber_unknown)
    ~meta ~keepalive_running ~agent_status ~quiet_reason ~now_ts () =
  (* Supervisor-level health takes priority *)
  match fiber_health with
  | Fiber_zombie -> "zombie"
  | Fiber_dead -> "dead"
  | _ ->
  let agent_exists = json_bool "exists" agent_status false in
  let agent_status_text =
    json_string_opt "status" agent_status
    |> Option.value ~default:"unknown"
    |> String.lowercase_ascii
  in
  let last_seen_ago_s =
    json_float_opt "last_seen_ago_s" agent_status |> Option.value ~default:max_float
  in
  let is_zombie = json_bool "is_zombie" agent_status false in
  let stale_threshold_s =
    float_of_int (max 120 (meta.presence_keepalive_sec * 4))
  in
  let last_turn_ago_s =
    if meta.last_turn_ts <= 0.0 then max_float
    else max 0.0 (now_ts -. meta.last_turn_ts)
  in
  if not agent_exists || agent_status_text = "offline" || agent_status_text = "inactive"
  then "offline"
  (* H-4 fix: report zombie/stale keepers regardless of keepalive state *)
  else if is_zombie || last_seen_ago_s > stale_threshold_s then
    "stale"
  else if not keepalive_running then
    "offline"
  else
    match quiet_reason with
    | Some "graphql_error" | Some "model_error" -> "degraded"
    | _ ->
        if meta.total_turns = 0 && meta.proactive_count_total = 0 then "idle"
        else if last_turn_ago_s > float_of_int (max meta.proactive_idle_sec 900)
        then "idle"
        else "healthy"

let keeper_next_action_path ~health_state ~quiet_reason =
  match health_state with
  | "zombie" -> "auto_restart"
  | "dead" -> "manual_restart"
  | "offline" | "stale" | "degraded" -> "recover"
  | _ -> (
      match quiet_reason with
      | Some "quiet_hours" -> "manual_lodge_poke"
      | Some "graphql_error" | Some "model_error" | Some "startup" | Some "unknown" ->
          "probe"
      | Some "disabled" -> "recover"
      | _ -> "direct_message")

let keeper_next_eligible_at_s ~meta ~quiet_reason ~now_ts =
  match quiet_reason with
  | Some "min_gap" when meta.last_proactive_ts > 0.0 ->
      let remaining =
        float_of_int meta.proactive_cooldown_sec -. (now_ts -. meta.last_proactive_ts)
      in
      if remaining > 0.0 then `Float remaining else `Null
  | _ -> `Null

let keeper_diagnostic_summary ~health_state ~quiet_reason =
  match health_state with
  | "zombie" ->
      "Keeper fiber has terminated but registry entry persists. Supervisor will auto-restart."
  | "dead" ->
      "Keeper restart budget exhausted. Manual restart via masc_keeper_up required."
  | "offline" | "stale" | "degraded" ->
      "Keeper is not in a healthy reply state. Probe or recover before relying on automation."
  | _ -> (
      match quiet_reason with
      | Some "quiet_hours" ->
          "Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep."
      | Some "min_gap" ->
          "Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait."
      | Some "never_started" ->
          "Keeper metadata exists but no reply turn has been recorded yet."
      | _ -> "Keeper is reachable. Send a direct message for an immediate response.")

let keeper_continuity_state
    ~(desired : bool)
    ~(meta : keeper_meta)
    ~(keepalive_running : bool)
    ~(keepalive_started_at : float option)
    ~(health_state : string)
    ~(now_ts : float) =
  let healthy_like =
    String.equal health_state "healthy" || String.equal health_state "idle"
  in
  let recently_started =
    match keepalive_started_at with
    | Some started_at ->
        let recovery_window_s =
          float_of_int (max 60 (min 600 (meta.presence_keepalive_sec * 2)))
        in
        now_ts -. started_at < recovery_window_s
    | None -> false
  in
  if desired && meta.presence_keepalive then
    if not keepalive_running then "desired_offline"
    else if recently_started || not healthy_like then "recovering"
    else "healthy"
  else if keepalive_running && healthy_like then "healthy"
  else if keepalive_running then "recovering"
  else "offline"

let keeper_continuity_summary continuity_state =
  match continuity_state with
  | "desired_offline" ->
      "Desired always-on keeper is offline. The runtime should reconcile it back into live presence."
  | "recovering" ->
      "Keeper runtime is reconciling back into live presence."
  | "healthy" ->
      "Keeper runtime is aligned with the desired live presence."
  | _ -> "Keeper runtime is offline."

let augment_keeper_diagnostic_json
    ~(desired : bool)
    ~(meta : keeper_meta)
    ~(keepalive_running : bool)
    ~(keepalive_started_at : float option)
    ~(now_ts : float)
    (diagnostic : Yojson.Safe.t) : Yojson.Safe.t =
  let health_state =
    json_string_opt "health_state" diagnostic |> Option.value ~default:"offline"
  in
  let continuity_state =
    keeper_continuity_state ~desired ~meta ~keepalive_running
      ~keepalive_started_at ~health_state ~now_ts
  in
  let continuity_summary = keeper_continuity_summary continuity_state in
  let summary =
    match json_string_opt "summary" diagnostic with
    | Some base when continuity_state = "healthy" -> base
    | Some _ | None -> continuity_summary
  in
  match diagnostic with
  | `Assoc fields ->
      let filtered =
        fields
        |> List.filter (fun (key, _) ->
               not
                 (String.equal key "summary"
                 || String.equal key "continuity_state"
                 || String.equal key "continuity_summary"))
      in
      `Assoc
        (("summary", `String summary)
        :: ("continuity_state", `String continuity_state)
        :: ("continuity_summary", `String continuity_summary)
        :: filtered)
  | other -> other

let keeper_surface_status
    ~(agent_status : Yojson.Safe.t)
    ~(diagnostic : Yojson.Safe.t) =
  let health_state =
    json_string_opt "health_state" diagnostic
    |> Option.value ~default:"offline"
    |> String.lowercase_ascii
  in
  if String.equal health_state "offline" then "offline"
  else
    match json_string_opt "status" agent_status with
    | Some status -> (
        match String.lowercase_ascii status with
        | ("active" | "busy" | "listening" | "idle") as status -> status
        | "offline" | "inactive" -> "offline"
        | _ -> (
            match health_state with
            | "idle" -> "idle"
            | "healthy" | "stale" | "degraded" -> "active"
            | _ -> "offline"))
    | None -> (
        match health_state with
        | "idle" -> "idle"
        | "healthy" | "stale" | "degraded" -> "active"
        | _ -> "offline")

let keeper_diagnostic_json
    ~(meta : keeper_meta)
    ~(agent_status : Yojson.Safe.t)
    ~(keepalive_running : bool)
    ~(history_items : Yojson.Safe.t list)
    ~(now_ts : float) : Yojson.Safe.t =
  let quiet_reason =
    classify_keeper_quiet_reason ~meta ~keepalive_running ~agent_status ~now_ts
  in
  let health_state =
    keeper_health_state ~meta ~keepalive_running ~agent_status ~quiet_reason ~now_ts ()
  in
  let next_action_path = keeper_next_action_path ~health_state ~quiet_reason in
  let last_reply_status, last_reply_at, last_reply_preview =
    keeper_reply_snapshot_of_history history_items
  in
  let last_error =
    match keeper_error_hint ~agent_status ~meta with
    | Some reason -> `String reason
    | None -> `Null
  in
  `Assoc
    [
      ("health_state", `String health_state);
      ( "quiet_reason",
        match quiet_reason with Some reason -> `String reason | None -> `Null );
      ("next_action_path", `String next_action_path);
      ("recoverable", `Bool (String.equal next_action_path "recover"));
      ("summary", `String (keeper_diagnostic_summary ~health_state ~quiet_reason));
      ("last_reply_status", last_reply_status);
      ("last_reply_at", last_reply_at);
      ("last_reply_preview", last_reply_preview);
      ("last_error", last_error);
      ("keepalive_running", `Bool keepalive_running);
      ("next_eligible_at_s", keeper_next_eligible_at_s ~meta ~quiet_reason ~now_ts);
    ]

(** Derive pipeline stage from keeper_meta timestamps.
    Uses recency thresholds to infer what the keeper is doing.
    Stages: "idle" | "thinking" | "tool_use" | "compacting" | "handoff"
            | "proactive" | "offline"
    The 30s recency window matches the typical keeper turn duration. *)
let derive_pipeline_stage
    ~(meta : keeper_meta)
    ~(surface_status : string)
    ~(now_ts : float)
  : string =
  if String.equal surface_status "offline" then "offline"
  else
    let recency_threshold = 30.0 in
    let turn_ago =
      if meta.last_turn_ts <= 0.0 then Float.infinity
      else now_ts -. meta.last_turn_ts
    in
    let compaction_ago =
      if meta.last_compaction_ts <= 0.0 then Float.infinity
      else now_ts -. meta.last_compaction_ts
    in
    let handoff_ago =
      if meta.last_handoff_ts <= 0.0 then Float.infinity
      else now_ts -. meta.last_handoff_ts
    in
    let proactive_ago =
      if meta.last_proactive_ts <= 0.0 then Float.infinity
      else now_ts -. meta.last_proactive_ts
    in
    (* Pick the most recent activity within the recency window.
       Priority order when multiple are recent: handoff > compacting > proactive > thinking *)
    if handoff_ago < recency_threshold then "handoff"
    else if compaction_ago < recency_threshold then "compacting"
    else if proactive_ago < recency_threshold then "proactive"
    else if turn_ago < recency_threshold then "thinking"
    else "idle"
