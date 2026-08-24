open Json_util

type agent = {
  name : string;
  status : string;
  current_task : string option;
  last_seen : string;
}

type task = {
  id : string;
  title : string;
  status : Masc_domain.task_status;
  priority : int;
}

type keeper = {
  k_name : string;
  k_trace_id : string;
  k_paused : bool;
  k_current_task_id : string option;
  k_total_turns : int;
  k_total_tokens : int;
  k_total_cost_usd : float;
  k_last_turn_ts : string;
  k_compaction_count : int;
  k_last_proactive_outcome : string;
  k_created_at : string;
  k_updated_at : string;
}

(* One row of GET /api/v1/gate/keepers. That route is [masc_keeper_list], which
   renders [status] through [Keeper_status_runtime.keeper_surface_status] — the
   six-member surface vocabulary, with no "paused" member. Operator pause is
   durable metadata and arrives on the [keeper] record instead, so a reader
   that wants the published control-plane status composes the two. Parsing the
   status into the closed variant here means a producer that grows a seventh
   label is a rejected row, not a row that silently reads as something else. *)
type keeper_phase = Keeper_state_machine.phase

let keeper_phase_of_string = Keeper_state_machine.phase_of_string

type keeper_health = Keeper_types.keeper_health
let keeper_health_to_string = Keeper_status_runtime.keeper_health_to_string
let keeper_health_of_string = Keeper_status_runtime.keeper_health_of_string_opt

let keeper_next_action_of_string =
  Keeper_status_runtime.keeper_next_action_path_of_string_opt
let keeper_phase_to_string = Keeper_state_machine.phase_to_string

type keeper_runtime = {
  kr_name : string;
  kr_health : keeper_health;
  kr_paused : bool;
  kr_next_action : Keeper_status_runtime.keeper_next_action_path option;
  kr_keepalive_running : bool;
  kr_autoboot_enabled : bool;
  kr_proactive_enabled : bool;
  kr_runtime_id : string;
  kr_phase : keeper_phase;
}

type keeper_lane_phase =
  | Lane_phase_offline
  | Lane_phase_running
  | Lane_phase_failing
  | Lane_phase_overflowed
  | Lane_phase_compacting
  | Lane_phase_handing_off
  | Lane_phase_draining
  | Lane_phase_paused
  | Lane_phase_stopped
  | Lane_phase_crashed
  | Lane_phase_restarting
  | Lane_phase_unknown of string

type keeper_lane_turn_phase =
  | Lane_turn_idle
  | Lane_turn_prompting
  | Lane_turn_routing
  | Lane_turn_executing
  | Lane_turn_compacting
  | Lane_turn_finalizing
  | Lane_turn_exhausted
  | Lane_turn_unknown of string

type keeper_lane_last_outcome = {
  klo_runtime_state : string;
  klo_selected_model : string option;
}

type keeper_lane = {
  kl_keeper : string;
  kl_phase : keeper_lane_phase;
  kl_turn_phase : keeper_lane_turn_phase;
  kl_idle_seconds : int;
  kl_last_outcome : keeper_lane_last_outcome option;
  kl_diagnosis : string option;
}

type keeper_lanes_snapshot = {
  kls_generated_at : float;
  kls_count : int;
  kls_lanes : keeper_lane list;
}

type fusion_run_status =
  | Fusion_running
  | Fusion_completed
  | Fusion_failed of {
      frs_failure_code : string;
      frs_error : string;
    }

type fusion_run = {
  fur_run_id : string;
  fur_keeper : string;
  fur_preset : string;
  fur_topology : Fusion_types.fusion_topology;
  fur_started_at : float;
  fur_status : fusion_run_status;
}

type fusion_snapshot = {
  fus_generated_at : string;
  fus_runs : fusion_run list;
}

type fusion_panel_answer = {
  fpa_model : string;
  fpa_answer : string;
  fpa_input_tokens : int;
  fpa_output_tokens : int;
}

type fusion_panel_failure = {
  fpf_model : string;
  fpf_reason_code : string;
  fpf_reason_detail : string;
}

type fusion_panel_result =
  | Fusion_panel_answered of fusion_panel_answer
  | Fusion_panel_failed of fusion_panel_failure

type fusion_judge =
  | Fusion_judge_synthesized of {
      fj_decision : string;
      fj_resolved_answer : string;
      fj_reason : string;
    }
  | Fusion_judge_failed of {
      fj_failure_code : string;
      fj_error : string;
    }

type fusion_evidence = {
  fe_post_id : string;
  fe_title : string;
  fe_question : string;
  fe_panel : fusion_panel_result list;
  fe_judge : fusion_judge;
}

type fusion_evidence_status =
  | Fusion_evidence_recorded
  | Fusion_evidence_pending
  | Fusion_evidence_absent

type fusion_detail = {
  fud_generated_at : string;
  fud_run : fusion_run;
  fud_evidence_status : fusion_evidence_status;
  fud_evidence : fusion_evidence option;
}

type goal_proof =
  | Proof_idle
  | Proof_pending
  | Proof_proven of string option
  | Proof_refuted of string option
  | Proof_unreadable of string option

type planning_goal = {
  pg_id : string;
  pg_title : string;
  pg_phase : Goal_phase.t;
  pg_priority : int;
  pg_due_date : string option;
  pg_metric : string option;
  pg_target_value : string option;
  pg_proof : goal_proof;
  pg_last_review_note : string option;
}

type planning_rollup = {
  pr_active : int;
  pr_verifying : int;
  pr_done : int;
  pr_dropped : int;
}

type planning_backlog = {
  pb_todo : int;
  pb_claimed : int;
  pb_running : int;
  pb_done : int;
  pb_cancelled : int;
}

type planning_snapshot = {
  pl_goals : planning_goal list;
  pl_rollup : planning_rollup;
  pl_backlog : planning_backlog;
  pl_generated_at : string;
}

(* One tool call a keeper is holding for an operator's answer, from
   GET /api/v1/keepers/tool-approvals. [kta_asked_at] is the server clock's
   epoch reading when the wait opened; the drawing side derives age from it. *)
type keeper_tool_approval = {
  kta_keeper : string;
  kta_tool_call_id : string;
  kta_tool : string;
  kta_args : string;
  kta_question : string;
  kta_asked_at : float;
  kta_timeout_sec : float;
}

type fleet_safety = {
  fs_status : string;
  fs_blocker : string option;
  fs_operator_action_required : bool;
  fs_bootable_count : int;
  fs_running_count : int;
  fs_executable_count : int;
  fs_failing_count : int;
  fs_recovering_count : int;
  fs_paused_count : int;
  fs_target_reaction_capacity : int;
  fs_reaction_capacity_shortfall : int;
  fs_bootable_names : string list;
  fs_running_names : string list;
  fs_executable_names : string list;
  fs_active_task_owner_without_fiber_count : int;
  fs_completion_authority_pending_count : int;
}

type log_kind =
  | Log_turn
  | Log_heartbeat

type log_channel =
  | Log_channel_turn
  | Log_channel_scheduled_autonomous
  | Log_channel_heartbeat

type log_entry = {
  le_kind : log_kind;
  le_ts : string;
  le_channel : log_channel;
  le_message_count : int option;
  le_input_tokens : int option;
  le_output_tokens : int option;
  le_latency_ms : int option;
  le_cost_usd : float option;
  le_work_kind : string option;
  le_tools_used : string list;
}

type context_unavailable_reason =
  | Context_measurement_missing
  | Context_turn_record_undecodable
  | Context_turn_record_read_failed
  | Context_turn_record_without_usage
  | Context_turn_record_trace_mismatch

type context_observation =
  | Context_observed of {
      ratio : float option;
      tokens : int;
      maximum : int option;
      observed_at : string;
      turn_ref : string;
    }
  | Context_unavailable of context_unavailable_reason

let ( let* ) = Result.bind

let member key json =
  match Json_util.assoc_member_opt key json with
  | Some v -> v
  | None -> `Null

let required_member json key =
  match Json_util.assoc_member_opt key json with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "missing required field '%s'" key)

let optional_string json key =
  match member key json with
  | `Null -> Ok None
  | `String s -> Ok (Some s)
  | other ->
      Error
        (Printf.sprintf "field '%s' must be a string (received %s)" key
           (Json_util.kind_name other))

let required_nullable_int_field json key =
  match Json_util.assoc_member_opt key json with
  | None -> Error (Printf.sprintf "missing required field '%s'" key)
  | Some `Null -> Ok None
  | Some (`Int n) -> Ok (Some n)
  | Some (`Intlit s) -> (
      match int_of_string_opt s with
      | Some n -> Ok (Some n)
      | None ->
          Error (Printf.sprintf "field '%s' has non-integer intlit %S" key s))
  | Some other ->
      Error
        (Printf.sprintf "field '%s' must be an int or null (received %s)" key
           (Json_util.kind_name other))

let required_nullable_float_field json key =
  match Json_util.assoc_member_opt key json with
  | None -> Error (Printf.sprintf "missing required field '%s'" key)
  | Some `Null -> Ok None
  | Some (`Float value) -> Ok (Some value)
  | Some (`Int value) -> Ok (Some (Float.of_int value))
  | Some other ->
      Error
        (Printf.sprintf "field '%s' must be a float or null (received %s)" key
           (Json_util.kind_name other))

let require_null_field json key =
  match Json_util.assoc_member_opt key json with
  | None -> Error (Printf.sprintf "missing required field '%s'" key)
  | Some `Null -> Ok ()
  | Some other ->
      Error
        (Printf.sprintf "field '%s' must be null (received %s)" key
           (Json_util.kind_name other))

let require_string_field json key = require_string json key
let require_int_field json key = require_int json key
let require_float_field json key = require_float json key
let require_string_list json key =
  match member key json with
  | `List items ->
      List.mapi
        (fun idx item ->
          match item with
          | `String value -> Ok value
          | bad ->
              Error
                (Printf.sprintf
                   "field '%s[%d]' must be a string (received %s)" key idx
                   (Json_util.kind_name bad)))
        items
      |> List.fold_left
           (fun acc item ->
             let* parsed = acc in
             let* value = item in
             Ok (value :: parsed))
           (Ok [])
      |> Result.map List.rev
  | `Null -> Error (Printf.sprintf "missing required field '%s'" key)
  | other ->
      Error
        (Printf.sprintf "field '%s' must be an array (received %s)" key
           (Json_util.kind_name other))

let decode_status json =
  match member "status" json with
  | `String s -> Ok s
  | `List (`String s :: _) -> Ok s
  | `List [] -> Error "field 'status' list must not be empty"
  | `List (bad :: _) ->
      Error
        (Printf.sprintf
           "field 'status' list head must be a string (received %s)"
           (Json_util.kind_name bad))
  | `Null -> Error "missing required field 'status'"
  | other ->
      Error
        (Printf.sprintf
           "field 'status' must be a string or non-empty string array \
            (received %s)"
           (Json_util.kind_name other))

let decode_agent json =
  let* name = require_string_field json "name" in
  let* status = decode_status json in
  let* current_task = optional_string json "current_task" in
  let* last_seen = require_string_field json "last_seen" in
  Ok { name; status; current_task; last_seen }

let task_of_domain (task : Masc_domain.task) =
  {
    id = task.id;
    title = task.title;
    status = task.task_status;
    priority = task.priority;
  }

let active_tasks_of_domain tasks =
  tasks
  |> List.map task_of_domain
  |> List.filter (fun task ->
       not (Masc_domain.task_status_is_terminal task.status))
  |> List.stable_sort (fun left right ->
       Int.compare left.priority right.priority)

let decode_task json =
  let* task = Masc_domain.task_of_yojson json in
  Ok (task_of_domain task)

let sanitize_terminal_text text =
  let escaped_byte byte = Printf.sprintf "\\x%02X" byte in
  let escaped_codepoint byte = Printf.sprintf "\\u00%02X" byte in
  let output = Buffer.create (String.length text) in
  let byte_at index = Char.code text.[index] in
  let is_continuation byte = byte >= 0x80 && byte <= 0xBF in
  let valid_utf8_length index =
    let remaining = String.length text - index in
    let first = byte_at index in
    if first >= 0xC2 && first <= 0xDF && remaining >= 2
       && is_continuation (byte_at (index + 1))
    then Some 2
    else if first = 0xE0 && remaining >= 3
            && byte_at (index + 1) >= 0xA0
            && byte_at (index + 1) <= 0xBF
            && is_continuation (byte_at (index + 2))
    then Some 3
    else if first >= 0xE1 && first <= 0xEC && remaining >= 3
            && is_continuation (byte_at (index + 1))
            && is_continuation (byte_at (index + 2))
    then Some 3
    else if first = 0xED && remaining >= 3
            && byte_at (index + 1) >= 0x80
            && byte_at (index + 1) <= 0x9F
            && is_continuation (byte_at (index + 2))
    then Some 3
    else if first >= 0xEE && first <= 0xEF && remaining >= 3
            && is_continuation (byte_at (index + 1))
            && is_continuation (byte_at (index + 2))
    then Some 3
    else if first = 0xF0 && remaining >= 4
            && byte_at (index + 1) >= 0x90
            && byte_at (index + 1) <= 0xBF
            && is_continuation (byte_at (index + 2))
            && is_continuation (byte_at (index + 3))
    then Some 4
    else if first >= 0xF1 && first <= 0xF3 && remaining >= 4
            && is_continuation (byte_at (index + 1))
            && is_continuation (byte_at (index + 2))
            && is_continuation (byte_at (index + 3))
    then Some 4
    else if first = 0xF4 && remaining >= 4
            && byte_at (index + 1) >= 0x80
            && byte_at (index + 1) <= 0x8F
            && is_continuation (byte_at (index + 2))
            && is_continuation (byte_at (index + 3))
    then Some 4
    else None
  in
  let rec append index =
    if index < String.length text
    then (
      let byte = Char.code text.[index] in
      if
        byte < 0x20 || (byte >= 0x7F && byte <= 0x9F)
      then (
        Buffer.add_string output (escaped_byte byte);
        append (index + 1))
      else if byte < 0x80
      then (
        Buffer.add_char output text.[index];
        append (index + 1))
      else if
        byte = 0xC2
        && index + 1 < String.length text
        && let next = Char.code text.[index + 1] in
           next >= 0x80 && next <= 0x9F
      then (
        Buffer.add_string output (escaped_codepoint (Char.code text.[index + 1]));
        append (index + 2))
      else
        match valid_utf8_length index with
        | Some length ->
          Buffer.add_substring output text index length;
          append (index + length)
        | None ->
          Buffer.add_string output (escaped_byte byte);
          append (index + 1))
  in
  append 0;
  Buffer.contents output
;;

let short_timestamp_for_terminal text =
  sanitize_terminal_text
    (if String.length text > 19 then String.sub text 0 19
     else if String.length text = 0 then "(never)"
     else text)
;;

(* The clock beside a row, in the zone the operator's terminal is in. The
   server writes RFC 3339 on the UTC timeline; slicing HH:MM:SS straight out
   of that string put a UTC clock on every log row under a header that showed
   local time, nine hours apart in Seoul. [localtime] is the conversion the
   caller chooses -- the terminal's own zone on a screen, a fixed one in a
   test -- so this stays a function of its inputs. A timestamp the codec
   cannot read keeps the old slice: the byte positions are still where a
   clock would be, and the sanitizer still makes them safe to draw. *)
let clock_timestamp_for_terminal ~localtime text =
  sanitize_terminal_text
    (match Time_codec.parse_rfc3339_opt text with
     | Some unix_seconds ->
         let tm = localtime unix_seconds in
         Printf.sprintf "%02d:%02d:%02d" tm.Unix.tm_hour tm.Unix.tm_min
           tm.Unix.tm_sec
     | None -> if String.length text >= 19 then String.sub text 11 8 else text)
;;

let keeper_of_meta (meta : Keeper_meta_contract.keeper_meta) =
  let runtime = meta.runtime in
  let usage = runtime.usage in
  let compaction = runtime.compaction_rt in
  let proactive = runtime.proactive_rt in
  let k_last_turn_ts =
    if Float.compare usage.last_turn_ts 0.0 <= 0 then ""
    else Masc_domain.iso8601_of_unix_seconds usage.last_turn_ts
  in
  {
    k_name = meta.name;
    k_trace_id = Keeper_id.Trace_id.to_string runtime.trace_id;
    k_paused = meta.paused;
    k_current_task_id =
      Option.map Keeper_id.Task_id.to_string meta.current_task_id;
    k_total_turns = usage.total_turns;
    k_total_tokens = usage.total_tokens;
    k_total_cost_usd = usage.total_cost_usd;
    k_last_turn_ts;
    k_compaction_count = compaction.count;
    k_last_proactive_outcome =
      Keeper_meta_contract.proactive_cycle_outcome_to_string
        proactive.last_outcome;
    k_created_at = meta.created_at;
    k_updated_at = meta.updated_at;
  }

let decode_keeper json =
  let* meta = Keeper_meta_json_parse.meta_of_json json in
  Ok (keeper_of_meta meta)

let decode_turn_channel raw =
  match Keeper_world_observation.channel_of_string raw with
  | Some Keeper_world_observation.Reactive -> Ok Log_channel_turn
  | Some Keeper_world_observation.Scheduled_autonomous ->
      Ok Log_channel_scheduled_autonomous
  | None -> Error (Printf.sprintf "unknown current turn channel %S" raw)

let decode_turn_mode json =
  let* raw = require_string_field json "turn_mode" in
  match Turn_mode_codec.turn_mode_of_string raw with
  | Some mode -> Ok mode
  | None -> Error (Printf.sprintf "unknown current turn mode %S" raw)

let validate_usage_projection ~input_tokens ~output_tokens
    ~cache_creation_tokens ~cache_read_tokens ~total_tokens ~cost_usd
    ~inner_trust ~inner_anomaly ~inner_reasons ~outer_trust ~outer_reasons =
  let classified =
    match
      ( input_tokens,
        output_tokens,
        cache_creation_tokens,
        cache_read_tokens,
        total_tokens,
        cost_usd )
    with
    | ( Some input_tokens,
        Some output_tokens,
        Some cache_creation_tokens,
        Some cache_read_tokens,
        Some total_tokens,
        Some cost_usd ) ->
        if total_tokens <> input_tokens + output_tokens then
          Error "usage total_tokens does not equal input_tokens + output_tokens"
        else
          let usage : Agent_core.Types.api_usage =
            { input_tokens;
              output_tokens;
              cache_creation_input_tokens = cache_creation_tokens;
              cache_read_input_tokens = cache_read_tokens;
              cost_usd = Some cost_usd;
            }
          in
          Ok (Keeper_usage_trust.classify ~usage_reported:true ~usage)
    | None, None, None, None, None, None ->
        let usage : Agent_core.Types.api_usage =
          { input_tokens = 0;
            output_tokens = 0;
            cache_creation_input_tokens = 0;
            cache_read_input_tokens = 0;
            cost_usd = None;
          }
        in
        Ok (Keeper_usage_trust.classify ~usage_reported:false ~usage)
    | _ ->
        Error
          "usage tokens, cost, and trust must form one current atomic observation"
  in
  let* classified = classified in
  let expected_trust = Keeper_usage_trust.to_string classified in
  let expected_reasons = Keeper_usage_trust.reasons classified in
  let expected_anomaly =
    match classified with
    | Keeper_usage_trust.Usage_untrusted _ -> true
    | Keeper_usage_trust.Usage_missing | Keeper_usage_trust.Usage_trusted ->
        false
  in
  if
    not
      (String.equal inner_trust expected_trust
      && String.equal outer_trust expected_trust)
  then Error "usage trust does not match the current counter observation"
  else if inner_anomaly <> expected_anomaly then
    Error "usage anomaly flag does not match the current trust classification"
  else if inner_reasons <> expected_reasons || outer_reasons <> expected_reasons
  then Error "usage anomaly reasons do not match the current trust classification"
  else Ok ()

let decode_log_entry json =
  let* kind =
    match Keeper_metrics_record.kind_of_json json with
    | Some kind -> Ok kind
    | None -> Error "unknown current keeper metrics schema or record kind"
  in
  let* le_ts = require_string_field json "ts" in
  let* _ts_unix = require_float_field json "ts_unix" in
  let* raw_channel = require_string_field json "channel" in
  let* _name = require_string_field json "name" in
  let* _agent_name = require_string_field json "agent_name" in
  let* _trace_id = require_string_field json "trace_id" in
  match kind with
  | Keeper_metrics_record.Heartbeat ->
      if not (String.equal raw_channel "heartbeat") then
        Error
          (Printf.sprintf "heartbeat metrics row has invalid channel %S"
             raw_channel)
      else
        let* le_message_count =
          required_nullable_int_field json "message_count"
        in
        let* () =
          if Option.exists (fun count -> count < 0) le_message_count then
            Error "heartbeat message_count must be non-negative"
          else Ok ()
        in
        Ok
          { le_kind = Log_heartbeat;
            le_ts;
            le_channel = Log_channel_heartbeat;
            le_message_count;
            le_input_tokens = None;
            le_output_tokens = None;
            le_latency_ms = None;
            le_cost_usd = None;
            le_work_kind = None;
            le_tools_used = [];
          }
  | Keeper_metrics_record.Turn ->
      let* le_channel = decode_turn_channel raw_channel in
      let* le_message_count = require_int_field json "message_count" in
      let* () =
        if le_message_count < 0 then
          Error "turn message_count must be non-negative"
        else Ok ()
      in
      let* usage =
        match member "usage" json with
        | `Assoc _ as usage -> Ok usage
        | `Null -> Error "missing required field 'usage'"
        | other ->
            Error
              (Printf.sprintf "field 'usage' must be an object (received %s)"
                 (Json_util.kind_name other))
      in
      let* le_input_tokens =
        required_nullable_int_field usage "input_tokens"
      in
      let* le_output_tokens =
        required_nullable_int_field usage "output_tokens"
      in
      let* cache_creation_tokens =
        required_nullable_int_field usage "cache_creation_tokens"
      in
      let* cache_read_tokens =
        required_nullable_int_field usage "cache_read_tokens"
      in
      let* total_tokens = required_nullable_int_field usage "total_tokens" in
      let* inner_usage_trust = require_string_field usage "usage_trust" in
      let* inner_usage_anomaly = require_bool usage "usage_anomaly" in
      let* inner_usage_anomaly_reasons =
        require_string_list usage "usage_anomaly_reasons"
      in
      let* outer_usage_trust = require_string_field json "usage_trust" in
      let* outer_usage_anomaly_reasons =
        require_string_list json "usage_anomaly_reasons"
      in
      let* latency_ms = require_int_field json "latency_ms" in
      let* () =
        if latency_ms < 0 then Error "latency_ms must be non-negative" else Ok ()
      in
      let* le_cost_usd = required_nullable_float_field json "cost_usd" in
      let* () =
        validate_usage_projection ~input_tokens:le_input_tokens
          ~output_tokens:le_output_tokens ~cache_creation_tokens
          ~cache_read_tokens ~total_tokens ~cost_usd:le_cost_usd
          ~inner_trust:inner_usage_trust
          ~inner_anomaly:inner_usage_anomaly
          ~inner_reasons:inner_usage_anomaly_reasons
          ~outer_trust:outer_usage_trust
          ~outer_reasons:outer_usage_anomaly_reasons
      in
      let* turn_mode = decode_turn_mode json in
      let* tool_call_count = require_int_field json "tool_call_count" in
      let* le_tools_used = require_string_list json "tools_used" in
      let* () =
        if tool_call_count < 0 then Error "tool_call_count must be non-negative"
        else if tool_call_count <> List.length le_tools_used then
          Error "tool_call_count does not match tools_used"
        else
          match turn_mode with
          | Turn_mode_codec.Tool_use -> Ok ()
          | Turn_mode_codec.Text_response
          | Turn_mode_codec.Skip_text
          | Turn_mode_codec.Noop ->
              if tool_call_count = 0 then Ok ()
              else Error "non-tool turn mode cannot carry tool calls"
      in
      Ok
        { le_kind = Log_turn;
          le_ts;
          le_channel;
          le_message_count = Some le_message_count;
          le_input_tokens;
          le_output_tokens;
          le_latency_ms = Some latency_ms;
          le_cost_usd;
          le_work_kind =
            Some (Turn_mode_codec.work_kind_of_turn_mode turn_mode);
          le_tools_used;
        }

let parse_log_entry line =
  let json =
    try Ok (Yojson.Safe.from_string line)
    with Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)
  in
  let* json = json in
  decode_log_entry json

let context_unavailable_reason_of_string = function
  | "context_measurement_missing" -> Ok Context_measurement_missing
  | "turn_record_undecodable" -> Ok Context_turn_record_undecodable
  | "turn_record_read_failed" -> Ok Context_turn_record_read_failed
  | "turn_record_without_usage" -> Ok Context_turn_record_without_usage
  | "turn_record_trace_mismatch" -> Ok Context_turn_record_trace_mismatch
  | raw -> Error (Printf.sprintf "unknown context unavailable reason %S" raw)

let context_unavailable_reason_to_string = function
  | Context_measurement_missing -> "context measurement missing"
  | Context_turn_record_undecodable -> "turn record undecodable"
  | Context_turn_record_read_failed -> "turn record read failed"
  | Context_turn_record_without_usage -> "turn record has no provider usage"
  | Context_turn_record_trace_mismatch -> "turn record belongs to a prior trace"

let require_object_member json key =
  let* value = required_member json key in
  match value with
  | `Assoc _ as object_value -> Ok object_value
  | other ->
      Error
        (Printf.sprintf "field '%s' must be an object (received %s)" key
           (Json_util.kind_name other))

let decode_context_unavailable_payload json =
  let* kind = require_string_field json "kind" in
  if not (String.equal kind "not_observed") then
    Error (Printf.sprintf "unknown context unavailable kind %S" kind)
  else
    let* reason = require_string_field json "reason" in
    context_unavailable_reason_of_string reason

let validate_context_ratio ~tokens ~maximum ~ratio =
  match maximum, ratio with
  | Some maximum, Some ratio when maximum > 0 ->
      let expected = Float.of_int tokens /. Float.of_int maximum in
      let tolerance = 1e-12 *. Float.max 1.0 (Float.abs expected) in
      if Float.is_finite ratio && Float.abs (ratio -. expected) <= tolerance then
        Ok ()
      else Error "context ratio does not match tokens / context window"
  | Some maximum, None when maximum > 0 ->
      Error "positive context window requires an observed ratio"
  | (None | Some 0), None -> Ok ()
  | (None | Some 0), Some _ ->
      Error "context ratio requires a positive context window"
  | Some _, (Some _ | None) -> Error "context window must be non-negative"

let decode_context_observation ~expected_trace_id json =
  match Json_util.assoc_member_opt "context_metrics_unavailable" json with
  | None -> Error "missing required field 'context_metrics_unavailable'"
  | Some (`Assoc _ as unavailable) ->
      let* reason = decode_context_unavailable_payload unavailable in
      let* () = require_null_field json "context_ratio" in
      let* () = require_null_field json "context_tokens" in
      let* () = require_null_field json "context_max" in
      let* () = require_null_field json "context_source" in
      let* context = require_object_member json "context" in
      let* () = require_null_field context "source" in
      let* () = require_null_field context "context_ratio" in
      let* () = require_null_field context "context_tokens" in
      let* () = require_null_field context "context_max" in
      let* nested_unavailable =
        require_object_member context "metrics_unavailable"
      in
      let* nested_reason =
        decode_context_unavailable_payload nested_unavailable
      in
      if nested_reason <> reason then
        Error "nested and top-level context unavailable reasons disagree"
      else Ok (Context_unavailable reason)
  | Some `Null ->
      let* ratio = required_nullable_float_field json "context_ratio" in
      let* tokens = require_int_field json "context_tokens" in
      let* maximum = required_nullable_int_field json "context_max" in
      let* source = require_string_field json "context_source" in
      if not (String.equal source "turn_record") then
        Error (Printf.sprintf "unknown context observation source %S" source)
      else if
        tokens < 0
        || Option.exists (fun value -> not (Float.is_finite value)) ratio
      then
        Error "context observation has an invalid numeric range"
      else
        let* () = validate_context_ratio ~tokens ~maximum ~ratio in
        let* context = require_object_member json "context" in
        let* nested_source = require_string_field context "source" in
        let* nested_ratio =
          required_nullable_float_field context "context_ratio"
        in
        let* nested_tokens = require_int_field context "context_tokens" in
        let* nested_maximum =
          required_nullable_int_field context "context_max"
        in
        let* () = require_null_field context "metrics_unavailable" in
        if not (String.equal nested_source source) then
          Error "nested and top-level context sources disagree"
        else if
          nested_ratio <> ratio || nested_tokens <> tokens
          || nested_maximum <> maximum
        then Error "nested and top-level context measurements disagree"
        else
          let* observed_at = require_string_field context "observed_at" in
          let* turn_ref_json = required_member context "turn_ref" in
          let* turn_ref = Ids.Turn_ref.of_yojson turn_ref_json in
          let* absolute_turn = require_int_field context "absolute_turn" in
          let* request_body_bytes =
            required_nullable_int_field context "request_body_bytes"
          in
          if
            not
              (String.equal (Ids.Turn_ref.trace_id turn_ref) expected_trace_id)
          then Error "context turn reference belongs to a different trace"
          else if absolute_turn <> Ids.Turn_ref.absolute_turn turn_ref then
            Error "context absolute turn disagrees with its turn reference"
          else if Option.exists (fun value -> value < 0) request_body_bytes then
            Error "context request body bytes must be non-negative"
          else
            Ok
              (Context_observed
                 { ratio;
                   tokens;
                   maximum;
                   observed_at;
                   turn_ref = Ids.Turn_ref.to_string turn_ref;
                 })
  | Some other ->
      Error
        (Printf.sprintf
           "field 'context_metrics_unavailable' must be an object or null (received %s)"
           (Json_util.kind_name other))

let trim = String.trim

let split_headers_body response =
  let marker = "\r\n\r\n" in
  let rec find idx =
    if idx + String.length marker > String.length response then None
    else if String.sub response idx (String.length marker) = marker then
      Some (idx + String.length marker)
    else
      find (idx + 1)
  in
  match find 0 with
  | Some idx -> Some (String.sub response idx (String.length response - idx))
  | None -> None

let is_success_http_status status_code = status_code >= 200 && status_code < 300

let http_status_error ~status_code ~body =
  let body = String.trim body in
  let detail =
    if body = "" then "empty response body"
    else if String.length body > 240 then String.sub body 0 240 ^ "..."
    else body
  in
  Printf.sprintf "HTTP %d: %s" status_code detail

let decode_json_response_body ~allow_empty ~status_code ~body :
    (Yojson.Safe.t, string) result =
  if not (is_success_http_status status_code) then
    Error (http_status_error ~status_code ~body)
  else if String.length (String.trim body) = 0 then
    if allow_empty then Ok (`Assoc []) else Error "empty response body"
  else
    try Ok (Yojson.Safe.from_string body)
    with Yojson.Json_error e -> Error (Printf.sprintf "(JSON parse: %s)" e)

(** The [/api/v1/tools/*] write endpoints answer one envelope,
    [{ok : bool; message : string}]. Reduced to a one-line outcome here so
    every call site reports the server's own message instead of re-decoding
    the envelope -- and a shape the endpoint never sends is an error rather
    than a guessed success. *)
let tool_envelope_outcome (json : Yojson.Safe.t) : (string, string) result =
  let envelope_message fields =
    match List.assoc_opt "message" fields with
    | Some (`String message) -> message
    | Some _ | None -> ""
  in
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "ok" fields with
      | Some (`Bool ok) ->
          let message = envelope_message fields in
          if ok then
            Ok (if String.equal message "" then "posted" else message)
          else
            Error
              (if String.equal message "" then "request rejected" else message)
      | _ -> Error "unexpected tool response envelope")
  | _ -> Error "unexpected tool response envelope"

(** Decode one SGR-encoded mouse report ([CSI ?1006;1000h] mode) into a key.

    A wheel report becomes [wheel-up] / [wheel-down] rather than the arrow keys
    it used to share. Two things wanted to be told apart: a wheel notch moves
    further than one row, and the chat composer answers the arrows with its own
    history. A surface that scrolls binds both. Wheel-up is button [64],
    wheel-down [65]; the horizontal wheel, clicks, and releases stay [None] -- the
    terminal sends them, but nothing consumes them yet, and an unconsumed
    report must not masquerade as a claimed key. [parameters] is the raw CSI
    parameter span (["<64;10;5"] for a wheel-up at column 10, row 5) and
    [final] the CSI final byte. *)
let sgr_wheel_key (parameters : string) (final : char) : string option =
  if final <> 'M' then None
  else
    match String.split_on_char ';' parameters with
    | button :: _ ->
        if String.equal button "<64" then Some "wheel-up"
        else if String.equal button "<65" then Some "wheel-down"
        else None
    | [] -> None

let missing_field key =
  Error (Printf.sprintf "missing required field '%s'" key)

let field_type_error key expected value =
  Error
    (Printf.sprintf "field '%s' must be %s (received %s)" key expected
       (Json_util.kind_name value))

let required_string_field json key =
  match member key json with
  | `String value -> Ok value
  | `Null -> missing_field key
  | bad -> field_type_error key "a string" bad

let optional_string_field json key =
  match member key json with
  | `String value -> Ok (Some value)
  | `Null -> Ok None
  | bad -> field_type_error key "a string or null" bad

let optional_bool_field json key =
  match member key json with
  | `Bool value -> Ok (Some value)
  | `Null -> Ok None
  | bad -> field_type_error key "a boolean or null" bad

let required_int_field json key =
  match member key json with
  | `Int value -> Ok value
  | `Intlit raw -> (
      match int_of_string_opt raw with
      | Some value -> Ok value
      | None -> Error (Printf.sprintf "field '%s' has invalid int %S" key raw))
  | `Null -> missing_field key
  | bad -> field_type_error key "an int" bad

let int_field_or json key ~default =
  match member key json with
  | `Null -> Ok default
  | _ -> required_int_field json key

let required_display_field json key =
  match member key json with
  | `String value -> Ok value
  | `Int value -> Ok (string_of_int value)
  | `Intlit value -> Ok value
  | `Float value -> Ok (Printf.sprintf "%.0f" value)
  | `Null -> missing_field key
  | bad -> field_type_error key "a scalar display value" bad

let required_display_any_field json keys =
  let rec loop = function
    | [] ->
        Error
          (Printf.sprintf "missing required field '%s'"
             (String.concat "' or '" keys))
    | key :: rest -> (
        match member key json with
        | `Null -> loop rest
        | _ -> required_display_field json key)
  in
  loop keys

let optional_body_field json =
  match member "body" json with
  | `String value -> Ok value
  | `Null -> (
      match member "content" json with
      | `String value -> Ok value
      | `Null -> Ok ""
      | bad -> field_type_error "content" "a string" bad)
  | bad -> field_type_error "body" "a string" bad

let required_body_field json =
  match member "body" json with
  | `String value -> Ok value
  | `Null -> required_string_field json "content"
  | bad -> field_type_error "body" "a string" bad

let required_list_field json key =
  match member key json with
  | `List items -> Ok items
  | `Null -> missing_field key
  | bad -> field_type_error key "an array" bad

let optional_list_field json key =
  match member key json with
  | `List items -> Ok items
  | `Null -> Ok []
  | bad -> field_type_error key "an array" bad

let required_object_field json key =
  match member key json with
  | `Assoc _ as obj -> Ok obj
  | `Null -> missing_field key
  | bad -> field_type_error key "an object" bad

let optional_object_field json key =
  match member key json with
  | `Assoc _ as obj -> Ok (Some obj)
  | `Null -> Ok None
  | bad -> field_type_error key "an object" bad

let decode_list label decode items =
  let rec loop idx acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest -> (
        match decode item with
        | Ok decoded -> loop (idx + 1) (decoded :: acc) rest
        | Error err -> Error (Printf.sprintf "%s[%d]: %s" label idx err))
  in
  loop 0 [] items

(* The ledger row the server joins onto each goal. Two shapes reach here: the
   record, whose [completion] names the state, and [ledger_error_to_yojson],
   which puts ["ledger_error"] at the top with a [detail]. Read leniently — this
   is a projection for a pane and a shape it cannot read must not cost the
   operator the goal list — but every branch says something different, so an
   unreadable ledger never renders as an unreviewed goal.

   The text comes from [evidence] before [reason]: an approval carries its text
   in [evidence] and leaves [reason] null, while a refusal fills both with the
   same string. *)
let decode_goal_proof json =
  let string_at container key =
    match member key container with
    | `String value when String.trim value <> "" -> Some (String.trim value)
    | `String _ | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _
    | `Null ->
      None
  in
  let verdict_text completion =
    let verdict = member "verdict" completion in
    match string_at verdict "evidence" with
    | Some _ as text -> text
    | None -> string_at verdict "reason"
  in
  match json with
  | `Assoc _ ->
    (match string_at json "state" with
     | Some "ledger_error" -> Proof_unreadable (string_at json "detail")
     | Some other -> Proof_unreadable (Some other)
     | None ->
       let completion = member "completion" json in
       (match string_at completion "state" with
        | Some "proof_proven" -> Proof_proven (verdict_text completion)
        | Some "proof_refuted" -> Proof_refuted (verdict_text completion)
        | Some "proof_pending" -> Proof_pending
        | Some "idle" -> Proof_idle
        | Some other -> Proof_unreadable (Some other)
        (* The server never leaves this out: a goal with no ledger row gets
           the default record and a store that will not decode gets the
           ledger_error marker, precisely so corruption is not dressed up as
           "not verified yet". Reading an absent state as idle would put that
           disguise back on this side of the wire. *)
        | None -> Proof_unreadable (Some "no completion state on the goal")))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Proof_unreadable (Some "no verification block on the goal")
;;

let decode_planning_goal json =
  let* pg_id = required_string_field json "id" in
  let* pg_title = required_string_field json "title" in
  let* raw_phase = required_string_field json "phase" in
  let* pg_phase =
    match Goal_phase.parse raw_phase with
    | Some phase -> Ok phase
    | None -> Error (Printf.sprintf "unknown planning goal phase %S" raw_phase)
  in
  let* pg_priority = required_int_field json "priority" in
  let* pg_due_date = optional_string_field json "due_date" in
  let* pg_metric = optional_string_field json "metric" in
  let* pg_target_value = optional_string_field json "target_value" in
  let* pg_last_review_note = optional_string_field json "last_review_note" in
  let pg_proof = decode_goal_proof (member "verification" json) in
  Ok
    {
      pg_id;
      pg_title;
      pg_phase;
      pg_priority;
      pg_due_date;
      pg_metric;
      pg_target_value;
      pg_proof;
      pg_last_review_note;
    }

let decode_planning_rollup json =
  let* pr_active = required_int_field json "active_count" in
  let* pr_verifying = required_int_field json "verifying_count" in
  let* pr_done = required_int_field json "done_count" in
  let* pr_dropped = required_int_field json "dropped_count" in
  Ok { pr_active; pr_verifying; pr_done; pr_dropped }

let decode_planning_backlog json =
  let* pb_todo = required_int_field json "todo" in
  let* pb_claimed = required_int_field json "claimed" in
  let* pb_running = required_int_field json "in_progress" in
  let* pb_done = required_int_field json "done" in
  let* pb_cancelled = required_int_field json "cancelled" in
  Ok { pb_todo; pb_claimed; pb_running; pb_done; pb_cancelled }

type system_log_level =
  | System_debug
  | System_info
  | System_warn
  | System_error
  | System_level_unknown of string

type keeper_call = {
  kc_at : float;
  kc_tool : string;
  kc_input : string;
  kc_output : string option;
  kc_success : bool;
  kc_duration_ms : float option;
  kc_turn : int option;
  kc_task_id : string option;
  kc_model : string option;
}

type keeper_calls_snapshot = {
  kcs_keeper : string;
  kcs_entries : keeper_call list;
  kcs_count : int;
  kcs_health : string;
  kcs_latest_age_s : float option;
  kcs_stale_reason : string option;
  kcs_mismatched : int;
}

type system_log_entry = {
  sl_seq : int;
  sl_ts : string;
  sl_level : system_log_level;
  sl_module : string;
  sl_keeper : string option;
  sl_message : string;
}

type system_log_snapshot = {
  sys_entries : system_log_entry list;
  sys_total : int;
  sys_latest_seq : int;
}

(* The server accepts "warn" and "warning" for one level and writes levels in
   upper case. An unrecognised spelling keeps its text instead of becoming
   Info, so a level added on the server shows up here as itself. *)
let system_log_level_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "debug" -> System_debug
  | "info" -> System_info
  | "warn" | "warning" -> System_warn
  | "error" -> System_error
  | _ -> System_level_unknown raw

let system_log_level_label = function
  | System_debug -> "DEBUG"
  | System_info -> "INFO "
  | System_warn -> "WARN "
  | System_error -> "ERROR"
  | System_level_unknown raw ->
      let raw = String.trim raw in
      if String.length raw >= 5 then String.sub raw 0 5
      else raw ^ String.make (5 - String.length raw) ' '

let decode_system_log_entry json =
  let* sl_seq = required_int_field json "seq" in
  let* sl_ts = required_string_field json "ts" in
  let* level_raw = required_string_field json "level" in
  let* sl_module = required_string_field json "module" in
  let* sl_message = required_string_field json "message" in
  let* sl_keeper = optional_string_field json "keeper_name" in
  Ok
    { sl_seq
    ; sl_ts
    ; sl_level = system_log_level_of_string level_raw
    ; sl_module
    ; sl_keeper
    ; sl_message
    }

type tool_entry = {
  tl_name : string;
  tl_description : string;
  tl_surfaces : string list;
  tl_direct_call : bool;
}

type inventory_freshness =
  | Warming
  | Settled

type tool_snapshot = {
  ts_tools : tool_entry list;
  ts_count : int;
  ts_freshness : inventory_freshness;
}

type connector = {
  cn_id : string;
  cn_display_name : string;
  cn_available : bool;
  cn_connected : bool;
  cn_status : string;
  cn_channel : string option;
}

type connector_snapshot = {
  cs_connectors : connector list;
  cs_total : int;
  cs_active : int;
}

type repository = {
  rp_name : string;
  rp_local_path : string;
  rp_default_branch : string;
  rp_status : string;
  rp_keepers : string list;
  rp_auto_sync : bool;
}

type repository_snapshot = {
  rs_repositories : repository list;
  rs_total : int;
}

type harness_verdict = {
  hv_at : float;
  hv_task_id : string;
  hv_task_title : string;
  hv_agent : string;
  hv_gate : string;
  hv_verdict : string;
  hv_evaluator : string;
  hv_fallback_reason : string option;
}

type harness_snapshot = { hs_verdicts : harness_verdict list }

type verification_request = {
  vr_request_id : string;
  vr_task_id : string;
  vr_task_title : string;
  vr_kind : string;
  vr_summary : string;
  vr_next_action : string option;
  vr_submitted_by : string;
  vr_created_at : string;
  vr_required_artifacts : string list;
  vr_submitted_evidence : string list;
  vr_evidence_error : string option;
}

type verification_snapshot = {
  vs_requests : verification_request list;
  vs_total : int;
}

let decode_string_name_list json key =
  let* items = optional_list_field json key in
  decode_list key
    (fun item ->
       match item with
       | `String value -> Ok value
       | bad -> field_type_error key "a string" bad)
    items

let decode_bool_field_or json key ~default =
  match member key json with
  | `Bool value -> Ok value
  | `Null -> Ok default
  | bad -> field_type_error key "a bool or null" bad

let decode_tool_entry json =
  let* tl_name = required_string_field json "name" in
  let* tl_description = required_string_field json "description" in
  let* tl_surfaces = decode_string_name_list json "surfaces" in
  let* tl_direct_call =
    decode_bool_field_or json "direct_call_allowed" ~default:false
  in
  Ok { tl_name; tl_description; tl_surfaces; tl_direct_call }

let decode_tool_snapshot json =
  (* The tools envelope carries config and runtime resolution beside the
     inventory; this reads the inventory and leaves the rest to the dashboard,
     which has room to show it. *)
  let* inventory = required_object_field json "tool_inventory" in
  let* tools_json = required_list_field inventory "tools" in
  let* ts_tools = decode_list "tools" decode_tool_entry tools_json in
  let* ts_count = required_int_field inventory "count" in
  (* Only the warming placeholder carries this flag, and it carries it as
     [true]; a payload built from a real inventory does not mention it. So an
     absent flag is a built inventory, and the pane can tell "the server has
     not looked yet" apart from "there are none" -- which it could not, and so
     reported a warming server as a workspace with no tools registered. *)
  let* warming = optional_bool_field json "is_warming" in
  let ts_freshness =
    match warming with Some true -> Warming | Some false | None -> Settled
  in
  Ok { ts_tools; ts_count; ts_freshness }

let decode_connector json =
  let* cn_id = required_string_field json "connector_id" in
  let* cn_display_name = required_string_field json "display_name" in
  let* cn_status = required_string_field json "status" in
  (* Both default to false: a connector that does not say it is available or
     connected is not, and defaulting the other way would draw a dead
     connector as a working one. *)
  let* cn_available = decode_bool_field_or json "available" ~default:false in
  let* cn_connected = decode_bool_field_or json "connected" ~default:false in
  let* cn_channel = optional_string_field json "channel" in
  Ok { cn_id; cn_display_name; cn_available; cn_connected; cn_status; cn_channel }

let decode_connector_snapshot json =
  let* connectors_json = required_list_field json "connectors" in
  let* cs_connectors =
    decode_list "connectors" decode_connector connectors_json
  in
  let* cs_total = required_int_field json "total" in
  let* cs_active = required_int_field json "active_count" in
  Ok { cs_connectors; cs_total; cs_active }

let decode_repository json =
  let* rp_name = required_string_field json "name" in
  let* rp_local_path = required_string_field json "local_path" in
  let* rp_default_branch = required_string_field json "default_branch" in
  let* rp_status = required_string_field json "status" in
  let* rp_keepers = decode_string_name_list json "keepers" in
  let* rp_auto_sync =
    match member "auto_sync" json with
    | `Bool value -> Ok value
    | `Null -> Ok false
    | bad -> field_type_error "auto_sync" "a bool or null" bad
  in
  Ok
    { rp_name; rp_local_path; rp_default_branch; rp_status; rp_keepers
    ; rp_auto_sync
    }

let decode_repository_snapshot json =
  let* repos_json = required_list_field json "repositories" in
  let* rs_repositories =
    decode_list "repositories" decode_repository repos_json
  in
  let* rs_total = required_int_field json "total" in
  Ok { rs_repositories; rs_total }

let decode_harness_verdict json =
  let* hv_task_id = required_string_field json "task_id" in
  let* hv_task_title = required_string_field json "task_title" in
  let* hv_agent = required_string_field json "agent_name" in
  let* hv_gate = required_string_field json "gate" in
  let* hv_verdict = required_string_field json "verdict" in
  let* hv_evaluator = required_string_field json "evaluator_runtime" in
  let* hv_fallback_reason = optional_string_field json "fallback_reason" in
  let* hv_at = require_float_field json "timestamp" in
  Ok
    { hv_at
    ; hv_task_id
    ; hv_task_title
    ; hv_agent
    ; hv_gate
    ; hv_verdict
    ; hv_evaluator
    ; hv_fallback_reason
    }

let decode_harness_snapshot json =
  let* verdicts_json = required_list_field json "recent_verdicts" in
  let* hs_verdicts =
    decode_list "recent_verdicts" decode_harness_verdict verdicts_json
  in
  Ok { hs_verdicts }

let decode_verification_request json =
  let* vr_request_id = required_string_field json "request_id" in
  let* vr_task_id = required_string_field json "task_id" in
  let* vr_task_title = required_string_field json "task_title" in
  let* vr_kind = required_string_field json "request_kind" in
  let* vr_summary = required_string_field json "request_summary" in
  let* vr_submitted_by = required_string_field json "submitted_by" in
  let* vr_created_at = required_string_field json "created_at" in
  let* vr_required_artifacts =
    decode_string_name_list json "required_artifacts"
  in
  let* vr_submitted_evidence =
    decode_string_name_list json "submitted_evidence"
  in
  let* vr_next_action = optional_string_field json "next_action" in
  let* vr_evidence_error =
    optional_string_field json "evidence_projection_error"
  in
  Ok
    { vr_request_id
    ; vr_task_id
    ; vr_task_title
    ; vr_kind
    ; vr_summary
    ; vr_next_action
    ; vr_submitted_by
    ; vr_created_at
    ; vr_required_artifacts
    ; vr_submitted_evidence
    ; vr_evidence_error
    }

let decode_verification_snapshot json =
  let* requests_json = required_list_field json "requests" in
  let* vs_requests =
    decode_list "requests" decode_verification_request requests_json
  in
  let* vs_total = required_int_field json "total" in
  Ok { vs_requests; vs_total }

let decode_keeper_call json =
  let* kc_at = require_float_field json "ts" in
  let* kc_tool = required_string_field json "tool" in
  let* keeper = required_string_field json "keeper" in
  let* kc_success =
    match member "success" json with
    | `Bool value -> Ok value
    | `Null -> Error "keeper call has no success field"
    | _ -> Error "keeper call success is not a bool"
  in
  let kc_input =
    match member "input" json with
    | `String value -> value
    | other -> Yojson.Safe.to_string other
  in
  (* What came back, as the server serves it. The row already said a call ran
     and what it was called with; without this it never said what the call
     answered, which is the question a failed call leaves open. The server
     bounds it (the envelope carries [truncated_to]), so this is a read, not a
     second budget. A row that carries no result says nothing rather than an
     empty string: "returned nothing" and "was not recorded" are different. *)
  let kc_output =
    match member "output" json with
    | `String value when String.trim value <> "" -> Some value
    | `String _ | `Null -> None
    | other -> Some (Yojson.Safe.to_string other)
  in
  let kc_duration_ms =
    match member "duration_ms" json with
    | `Float value -> Some value
    | `Int value -> Some (float_of_int value)
    | _ -> None
  in
  let kc_turn = match member "turn" json with `Int value -> Some value | _ -> None in
  let string_opt key =
    match member key json with
    | `String value when String.trim value <> "" -> Some value
    | _ -> None
  in
  Ok
    ( keeper
    , { kc_at
      ; kc_tool
      ; kc_input
      ; kc_output
      ; kc_success
      ; kc_duration_ms
      ; kc_turn
      ; kc_task_id = string_opt "task_id"
      ; kc_model = string_opt "model"
      } )

let decode_keeper_calls_snapshot ~requested_keeper json =
  let* kcs_keeper = required_string_field json "keeper" in
  let* kcs_count = required_int_field json "count" in
  let* kcs_health = required_string_field json "health" in
  let* entries_json = required_list_field json "entries" in
  let* rows =
    decode_list "entries" decode_keeper_call entries_json
  in
  (* A row naming another keeper is the store's problem to surface, not a
     row to draw under this keeper's name. *)
  let kcs_entries, kcs_mismatched =
    List.fold_left
      (fun (kept, mismatched) (keeper, row) ->
        if String.equal keeper requested_keeper then (row :: kept, mismatched)
        else (kept, mismatched + 1))
      ([], 0) rows
  in
  let kcs_latest_age_s =
    match member "latest_age_s" json with
    | `Float value -> Some value
    | `Int value -> Some (float_of_int value)
    | _ -> None
  in
  let kcs_stale_reason =
    match member "stale_reason" json with
    | `String value when String.trim value <> "" && not (String.equal value "fresh")
      ->
        Some value
    | _ -> None
  in
  Ok
    { kcs_keeper
    ; kcs_entries = List.rev kcs_entries
    ; kcs_count
    ; kcs_health
    ; kcs_latest_age_s
    ; kcs_stale_reason
    ; kcs_mismatched
    }

let decode_system_log_snapshot json =
  let* entries_json = required_list_field json "entries" in
  let* sys_entries = decode_list "entries" decode_system_log_entry entries_json in
  let* sys_total = required_int_field json "total" in
  let* sys_latest_seq = required_int_field json "latest_seq" in
  Ok { sys_entries; sys_total; sys_latest_seq }

let decode_planning_snapshot json =
  let* goals_json = required_list_field json "goals" in
  let* pl_goals = decode_list "goals" decode_planning_goal goals_json in
  let* rollup_json = required_object_field json "rollup" in
  let* pl_rollup = decode_planning_rollup rollup_json in
  let* backlog_json = required_object_field json "task_backlog" in
  let* pl_backlog = decode_planning_backlog backlog_json in
  let* pl_generated_at = required_string_field json "generated_at" in
  Ok { pl_goals; pl_rollup; pl_backlog; pl_generated_at }

let required_bool_field json key =
  match member key json with
  | `Bool value -> Ok value
  | `Null -> missing_field key
  | bad -> field_type_error key "a bool" bad

let decode_keeper_runtime json =
  let* kr_name = required_string_field json "name" in
  let* raw_health = required_string_field json "health" in
  let* kr_health =
    match keeper_health_of_string raw_health with
    | Some health -> Ok health
    | None ->
        Error
          (Printf.sprintf "keeper %S has unknown health %S" kr_name raw_health)
  in
  let* kr_paused = required_bool_field json "paused" in
  (* An absent action is absent, not a default one: the server publishes null
     when the diagnostic named none, and a keeper with nothing to do is a
     different reading from a keeper whose action this build cannot spell. *)
  let* kr_next_action =
    match member "next_action" json with
    | `Null -> Ok None
    | `String raw -> (
      match keeper_next_action_of_string raw with
      | Some action -> Ok (Some action)
      | None ->
          Error
            (Printf.sprintf "keeper %S has unknown next action %S" kr_name raw))
    | bad -> field_type_error "next_action" "a string or null" bad
  in
  let* kr_keepalive_running = required_bool_field json "keepalive_running" in
  let* kr_autoboot_enabled = required_bool_field json "autoboot_enabled" in
  let* kr_proactive_enabled = required_bool_field json "proactive_enabled" in
  let* kr_runtime_id = required_string_field json "runtime_id" in
  let* raw_phase = required_string_field json "phase" in
  let* kr_phase =
    match keeper_phase_of_string raw_phase with
    | Some phase -> Ok phase
    | None ->
        Error
          (Printf.sprintf "keeper %S has unknown lifecycle phase %S" kr_name
             raw_phase)
  in
  Ok
    { kr_name
    ; kr_health
    ; kr_paused
    ; kr_next_action
    ; kr_keepalive_running
    ; kr_autoboot_enabled
    ; kr_proactive_enabled
    ; kr_runtime_id
    ; kr_phase
    }

(* [truncated] is carried out rather than dropped: the route clamps its own
   limit, so a workspace with more keepers than one response holds would
   otherwise present a short list as the whole fleet. *)
let decode_keeper_runtime_list json =
  let* items = required_list_field json "keepers" in
  let* rows = decode_list "keepers" decode_keeper_runtime items in
  let* truncated =
    match member "truncated" json with
    | `Bool value -> Ok value
    | `Null -> Ok false
    | bad -> field_type_error "truncated" "a bool or null" bad
  in
  let* total = int_field_or json "total" ~default:(List.length rows) in
  Ok (rows, truncated, total)

let keeper_lane_phase_of_string raw =
  match keeper_phase_of_string raw with
  | None -> Lane_phase_unknown raw
  | Some phase -> (
      match phase with
      | Keeper_state_machine.Offline -> Lane_phase_offline
      | Keeper_state_machine.Running -> Lane_phase_running
      | Keeper_state_machine.Failing -> Lane_phase_failing
      | Keeper_state_machine.Overflowed -> Lane_phase_overflowed
      | Keeper_state_machine.Compacting -> Lane_phase_compacting
      | Keeper_state_machine.HandingOff -> Lane_phase_handing_off
      | Keeper_state_machine.Draining -> Lane_phase_draining
      | Keeper_state_machine.Paused -> Lane_phase_paused
      | Keeper_state_machine.Stopped -> Lane_phase_stopped
      | Keeper_state_machine.Crashed -> Lane_phase_crashed
      | Keeper_state_machine.Restarting -> Lane_phase_restarting)

let keeper_lane_phase_to_string = function
  | Lane_phase_offline -> keeper_phase_to_string Keeper_state_machine.Offline
  | Lane_phase_running -> keeper_phase_to_string Keeper_state_machine.Running
  | Lane_phase_failing -> keeper_phase_to_string Keeper_state_machine.Failing
  | Lane_phase_overflowed ->
      keeper_phase_to_string Keeper_state_machine.Overflowed
  | Lane_phase_compacting ->
      keeper_phase_to_string Keeper_state_machine.Compacting
  | Lane_phase_handing_off ->
      keeper_phase_to_string Keeper_state_machine.HandingOff
  | Lane_phase_draining -> keeper_phase_to_string Keeper_state_machine.Draining
  | Lane_phase_paused -> keeper_phase_to_string Keeper_state_machine.Paused
  | Lane_phase_stopped -> keeper_phase_to_string Keeper_state_machine.Stopped
  | Lane_phase_crashed -> keeper_phase_to_string Keeper_state_machine.Crashed
  | Lane_phase_restarting ->
      keeper_phase_to_string Keeper_state_machine.Restarting
  | Lane_phase_unknown raw -> raw

let keeper_lane_turn_phase_of_string = function
  | "idle" -> Lane_turn_idle
  | "prompting" -> Lane_turn_prompting
  | "routing" -> Lane_turn_routing
  | "executing" -> Lane_turn_executing
  | "compacting" -> Lane_turn_compacting
  | "finalizing" -> Lane_turn_finalizing
  | "exhausted" -> Lane_turn_exhausted
  | raw -> Lane_turn_unknown raw

let keeper_lane_turn_phase_to_string = function
  | Lane_turn_idle -> "idle"
  | Lane_turn_prompting -> "prompting"
  | Lane_turn_routing -> "routing"
  | Lane_turn_executing -> "executing"
  | Lane_turn_compacting -> "compacting"
  | Lane_turn_finalizing -> "finalizing"
  | Lane_turn_exhausted -> "exhausted"
  | Lane_turn_unknown raw -> raw

let required_nullable_string_field json key =
  match Json_util.assoc_member_opt key json with
  | None -> missing_field key
  | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some bad -> field_type_error key "a string or null" bad

let decode_keeper_lane_last_outcome json =
  let* klo_runtime_state = required_string_field json "runtime_state" in
  let* klo_selected_model =
    required_nullable_string_field json "selected_model"
  in
  Ok { klo_runtime_state; klo_selected_model }

let decode_keeper_lane json =
  let* kl_keeper = required_string_field json "keeper" in
  let* raw_phase = required_string_field json "phase" in
  let kl_phase = keeper_lane_phase_of_string raw_phase in
  let* raw_turn_phase = required_string_field json "turn_phase" in
  let kl_turn_phase = keeper_lane_turn_phase_of_string raw_turn_phase in
  let* kl_idle_seconds = required_int_field json "idle_seconds" in
  let* kl_last_outcome =
    match Json_util.assoc_member_opt "last_outcome" json with
    | None -> missing_field "last_outcome"
    | Some `Null -> Ok None
    | Some (`Assoc _ as outcome) ->
        let* decoded = decode_keeper_lane_last_outcome outcome in
        Ok (Some decoded)
    | Some bad -> field_type_error "last_outcome" "an object or null" bad
  in
  let* diagnosis = required_object_field json "phase_diagnosis" in
  let* kl_diagnosis =
    required_nullable_string_field diagnosis "determining_condition"
  in
  Ok
    { kl_keeper
    ; kl_phase
    ; kl_turn_phase
    ; kl_idle_seconds
    ; kl_last_outcome
    ; kl_diagnosis
    }

let decode_keeper_lanes_snapshot json =
  let* kls_generated_at = require_float_field json "generated_at" in
  let* kls_count = required_int_field json "count" in
  let* items = required_list_field json "snapshots" in
  let* kls_lanes = decode_list "snapshots" decode_keeper_lane items in
  Ok { kls_generated_at; kls_count; kls_lanes }

let fusion_run_status_to_string = function
  | Fusion_running -> "running"
  | Fusion_completed -> "completed"
  | Fusion_failed _ -> "failed"

let decode_fusion_run json =
  let* fur_run_id = required_string_field json "run_id" in
  let* fur_keeper = required_string_field json "keeper" in
  let* fur_preset = required_string_field json "preset" in
  let* topology = required_string_field json "topology" in
  let* fur_topology =
    match Fusion_types.fusion_topology_of_string topology with
    | Some topology -> Ok topology
    | None -> Error (Printf.sprintf "unknown fusion topology %S" topology)
  in
  let* fur_started_at = require_float_field json "started_at" in
  let* status = required_string_field json "status" in
  let* fur_status =
    match status with
    | "running" -> Ok Fusion_running
    | "completed" -> Ok Fusion_completed
    | "failed" ->
        let* frs_failure_code = required_string_field json "failure_code" in
        let* frs_error = required_string_field json "error" in
        Ok (Fusion_failed { frs_failure_code; frs_error })
    | other -> Error (Printf.sprintf "unknown fusion run status %S" other)
  in
  Ok
    { fur_run_id
    ; fur_keeper
    ; fur_preset
    ; fur_topology
    ; fur_started_at
    ; fur_status
    }

let decode_fusion_snapshot json =
  let* fus_generated_at = required_string_field json "generated_at" in
  let* count = required_int_field json "count" in
  let* runs_json = required_list_field json "runs" in
  let* fus_runs = decode_list "runs" decode_fusion_run runs_json in
  if count <> List.length fus_runs then
    Error
      (Printf.sprintf "fusion run count is %d but runs contains %d rows" count
         (List.length fus_runs))
  else Ok { fus_generated_at; fus_runs }

let decode_fusion_panel_result json =
  let* model = required_string_field json "model" in
  let* status = required_string_field json "status" in
  match status with
  | "answered" ->
      let* fpa_answer = required_string_field json "answer" in
      let* fpa_input_tokens = required_int_field json "input_tokens" in
      let* fpa_output_tokens = required_int_field json "output_tokens" in
      Ok
        (Fusion_panel_answered
           { fpa_model = model
           ; fpa_answer
           ; fpa_input_tokens
           ; fpa_output_tokens
           })
  | "failed" ->
      let* fpf_reason_code = required_string_field json "reason_code" in
      let* fpf_reason_detail = required_string_field json "reason_detail" in
      Ok
        (Fusion_panel_failed
           { fpf_model = model; fpf_reason_code; fpf_reason_detail })
  | other -> Error (Printf.sprintf "unknown fusion panel status %S" other)

let decode_fusion_judge json =
  let* status = required_string_field json "status" in
  match status with
  | "synthesized" ->
      let* fj_decision = required_string_field json "decision" in
      let* fj_resolved_answer = required_string_field json "resolved_answer" in
      let* fj_reason = required_string_field json "synthesis" in
      Ok
        (Fusion_judge_synthesized
           { fj_decision; fj_resolved_answer; fj_reason })
  | "failed" ->
      let* fj_failure_code = required_string_field json "failure_code" in
      let* fj_error = required_string_field json "error" in
      Ok (Fusion_judge_failed { fj_failure_code; fj_error })
  | other -> Error (Printf.sprintf "unknown fusion judge status %S" other)

let decode_fusion_evidence ~run_id json =
  let* fe_post_id = required_string_field json "id" in
  let* fe_title = required_string_field json "title" in
  let* origin = required_object_field json "origin" in
  let* source = required_string_field origin "source" in
  let* origin_run_id = required_string_field origin "fusion_run_id" in
  let* () =
    if String.equal source "fusion" then Ok ()
    else
      Error
        (Printf.sprintf "fusion evidence origin.source is %S, expected \"fusion\""
           source)
  in
  let* () =
    if String.equal origin_run_id run_id then Ok ()
    else
      Error
        (Printf.sprintf
           "fusion evidence origin run id is %S, expected %S" origin_run_id
           run_id)
  in
  let* meta = required_object_field json "meta" in
  let* fe_question = required_string_field meta "question" in
  let* panel_json = required_list_field meta "panel" in
  let* fe_panel = decode_list "panel" decode_fusion_panel_result panel_json in
  let* judge_json = required_object_field meta "judge" in
  let* fe_judge = decode_fusion_judge judge_json in
  Ok { fe_post_id; fe_title; fe_question; fe_panel; fe_judge }

let decode_fusion_detail json =
  let* fud_generated_at = required_string_field json "generated_at" in
  let* run_json = required_object_field json "run" in
  let* fud_run = decode_fusion_run run_json in
  let* evidence = required_object_field json "evidence" in
  let* status = required_string_field evidence "status" in
  let* post =
    match Json_util.assoc_member_opt "post" evidence with
    | None -> missing_field "post"
    | Some post -> Ok post
  in
  match status, post with
  | "recorded", (`Assoc _ as post_json) ->
      let* fud_evidence =
        decode_fusion_evidence ~run_id:fud_run.fur_run_id post_json
      in
      Ok
        { fud_generated_at
        ; fud_run
        ; fud_evidence_status = Fusion_evidence_recorded
        ; fud_evidence = Some fud_evidence
        }
  | "recorded", bad ->
      field_type_error "evidence.post" "an object when status is recorded" bad
  | "pending", `Null ->
      (match fud_run.fur_status with
       | Fusion_running ->
           Ok
             { fud_generated_at
             ; fud_run
             ; fud_evidence_status = Fusion_evidence_pending
             ; fud_evidence = None
             }
       | Fusion_completed | Fusion_failed _ ->
           Error "only a running fusion run may have pending evidence")
  | "pending", _ -> Error "pending fusion evidence must carry post:null"
  | "absent", `Null ->
      (match fud_run.fur_status with
       | Fusion_running ->
           Error "a running fusion run cannot have absent evidence"
       | Fusion_completed | Fusion_failed _ ->
           Ok
             { fud_generated_at
             ; fud_run
             ; fud_evidence_status = Fusion_evidence_absent
             ; fud_evidence = None
             })
  | "absent", _ -> Error "absent fusion evidence must carry post:null"
  | other, _ -> Error (Printf.sprintf "unknown fusion evidence status %S" other)

(* The counts are read with a default rather than required: the server adds
   fields to this section over time, and a TUI that refuses the whole reading
   because one counter is new would hide the fleet exactly when it changed.
   The three that name the fleet's own verdict -- status, blocker, and whether
   an operator has to act -- are required, because a reading without them says
   nothing. *)
let decode_keeper_tool_approval json =
  let* kta_keeper = required_string_field json "keeper" in
  let* kta_tool_call_id = required_string_field json "tool_call_id" in
  let* kta_tool = required_string_field json "tool" in
  let* kta_args = required_string_field json "args" in
  let* kta_question = required_string_field json "question" in
  let* kta_asked_at = require_float_field json "asked_at" in
  let* kta_timeout_sec = require_float_field json "timeout_sec" in
  Ok
    { kta_keeper
    ; kta_tool_call_id
    ; kta_tool
    ; kta_args
    ; kta_question
    ; kta_asked_at
    ; kta_timeout_sec
    }

(* GET /api/v1/keepers/tool-approval-mode: the keepers moved off the default
   stance. Decoded to (keeper, mode) pairs; the caller decides what a mode
   means — this module carries the wire vocabulary only. *)
let decode_tool_approval_mode_overrides json =
  let* items = required_list_field json "overrides" in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
        let* keeper = required_string_field item "keeper" in
        let* mode = required_string_field item "mode" in
        loop ((keeper, mode) :: acc) rest
  in
  loop [] items

let decode_keeper_tool_approvals json =
  let* items = required_list_field json "pending" in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
        let* decoded = decode_keeper_tool_approval item in
        loop (decoded :: acc) rest
  in
  loop [] items

(* GET /api/v1/runtime/resolved, the slice the runtime picker draws: every
   runtime a keeper can be pointed at, and where each keeper points today. *)
type runtime_option = {
  ro_id : string;
  ro_provider : string;
  ro_model : string;
  ro_dispatchable : bool;
  ro_is_default : bool;
}

type runtime_assignment = {
  ra_keeper : string;
  ra_source : string;  (* "default" | "explicit" *)
  ra_runtime_id : string option;
}

let decode_runtime_option json =
  let* ro_id = required_string_field json "id" in
  let* ro_provider = required_string_field json "provider" in
  let* ro_model = required_string_field json "model" in
  let* ro_dispatchable =
    match member "keeper_dispatchable" json with
    | `Bool value -> Ok value
    | `Null -> Ok false
    | bad -> field_type_error "keeper_dispatchable" "a bool or null" bad
  in
  let* ro_is_default =
    match member "is_default" json with
    | `Bool value -> Ok value
    | `Null -> Ok false
    | bad -> field_type_error "is_default" "a bool or null" bad
  in
  Ok { ro_id; ro_provider; ro_model; ro_dispatchable; ro_is_default }

let decode_runtime_assignment json =
  let* ra_keeper = required_string_field json "keeper" in
  let* ra_source = required_string_field json "assignment_source" in
  let* ra_runtime_id =
    match member "resolved" json with
    | `Null -> Ok None
    | resolved ->
        let* id = required_string_field resolved "id" in
        Ok (Some id)
  in
  Ok { ra_keeper; ra_source; ra_runtime_id }

let decode_runtime_resolved json =
  let* runtime_items = required_list_field json "runtimes" in
  let* assignment_items = required_list_field json "assignments" in
  let rec map_all decode acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
        let* decoded = decode item in
        map_all decode (decoded :: acc) rest
  in
  let* runtimes = map_all decode_runtime_option [] runtime_items in
  let* assignments = map_all decode_runtime_assignment [] assignment_items in
  Ok (runtimes, assignments)

let decode_fleet_safety json =
  let* section = required_object_field json "keeper_fleet_safety" in
  let* fs_status = required_string_field section "status" in
  let* fs_blocker = optional_string_field section "blocker" in
  let* fs_operator_action_required =
    match member "operator_action_required" section with
    | `Bool value -> Ok value
    | `Null -> Ok false
    | bad -> field_type_error "operator_action_required" "a bool or null" bad
  in
  let* fs_bootable_count = int_field_or section "bootable_keeper_count" ~default:0 in
  let* fs_running_count = int_field_or section "running_keeper_fiber_count" ~default:0 in
  let* fs_executable_count =
    int_field_or section "executable_keeper_fiber_count" ~default:0
  in
  let* fs_failing_count = int_field_or section "failing_keeper_fiber_count" ~default:0 in
  let* fs_recovering_count =
    int_field_or section "recovering_keeper_fiber_count" ~default:0
  in
  let* fs_paused_count = int_field_or section "paused_keeper_count" ~default:0 in
  let* fs_target_reaction_capacity =
    int_field_or section "target_reaction_capacity_count" ~default:0
  in
  let* fs_reaction_capacity_shortfall =
    int_field_or section "reaction_capacity_shortfall_count" ~default:0
  in
  let* fs_bootable_names = decode_string_name_list section "bootable_keeper_names" in
  let* fs_running_names = decode_string_name_list section "running_keeper_names" in
  let* fs_executable_names =
    decode_string_name_list section "executable_keeper_names"
  in
  let* fs_active_task_owner_without_fiber_count =
    int_field_or section "active_task_owner_without_executable_fiber_count" ~default:0
  in
  let* fs_completion_authority_pending_count =
    int_field_or section "completion_authority_pending_task_count" ~default:0
  in
  Ok
    { fs_status
    ; fs_blocker
    ; fs_operator_action_required
    ; fs_bootable_count
    ; fs_running_count
    ; fs_executable_count
    ; fs_failing_count
    ; fs_recovering_count
    ; fs_paused_count
    ; fs_target_reaction_capacity
    ; fs_reaction_capacity_shortfall
    ; fs_bootable_names
    ; fs_running_names
    ; fs_executable_names
    ; fs_active_task_owner_without_fiber_count
    ; fs_completion_authority_pending_count
    }

let bounded_parent_depth ?(max_depth = 64) ~(id_of : 'a -> string)
    ~(parent_id_of : 'a -> string option) (items : 'a list) (item : 'a) : int =
  let module StringSet = Set.Make (String) in
  let rec loop seen depth current =
    if depth >= max_depth then depth
    else
      match parent_id_of current with
      | None -> depth
      | Some parent_id when StringSet.mem parent_id seen -> depth
      | Some parent_id -> (
          match List.find_opt (fun candidate -> id_of candidate = parent_id) items with
          | Some parent ->
              loop (StringSet.add parent_id seen) (depth + 1) parent
          | None -> depth)
  in
  loop (StringSet.singleton (id_of item)) 0 item

type chat_event =
  | Delta of string
  | Complete of string
  | Ignore

let decode_chat_event json =
  let event_type = get_string json "type" in
  match event_type with
  | Some ("TEXT_MESSAGE_CONTENT" | "content_delta" | "delta") -> (
      match get_string json "delta" with
      | Some text -> Ok (Delta text)
      | None -> Error "delta event missing string 'delta'")
  | Some ("RUN_FINISHED" | "content_complete" | "complete") -> (
      match get_string json "text" with
      | Some text -> Ok (Complete text)
      | None -> Ok (Complete ""))
  | Some "RUN_ERROR" -> (
      match get_string json "message" with
      | Some message -> Error message
      | None -> (
          match get_object json "error" with
          | Some err_json -> (
              match get_string err_json "message" with
              | Some message -> Error message
              | None -> Error "RUN_ERROR payload missing string 'message'")
          | None -> Error "RUN_ERROR payload missing string 'message'"))
  | _ -> (
      match get_object json "error" with
      | Some err_json -> (
          match get_string err_json "message" with
          | Some message -> Error message
          | None -> Error "error payload missing string 'message'")
      | None -> Ok Ignore)

let parse_keeper_chat_response response =
  let lines = String.split_on_char '\n' response in
  let result = Buffer.create 256 in
  let completion_text = ref None in
  let saw_terminal = ref false in
  let rec consume_sse = function
    | [] -> Ok ()
    | raw_line :: rest ->
        let line = trim raw_line in
        if String.length line > 6 && String.starts_with line ~prefix:"data: " then (
          let payload = String.sub line 6 (String.length line - 6) |> trim in
          if payload = "[DONE]" || payload = "" then consume_sse rest
          else
            let* json =
              try Ok (Yojson.Safe.from_string payload)
              with Yojson.Json_error msg ->
                Error ("invalid SSE JSON payload: " ^ msg)
            in
            let* chunk = decode_chat_event json in
            (match chunk with
             | Delta text -> Buffer.add_string result text
             | Complete text when Buffer.length result = 0 ->
                 saw_terminal := true;
                 if text <> "" then completion_text := Some text
             | Complete _ -> saw_terminal := true
             | Ignore -> ());
            consume_sse rest
        ) else
          consume_sse rest
  in
  let* () = consume_sse lines in
  if Buffer.length result > 0 then
    Ok (Buffer.contents result)
  else
    match !completion_text with
    | Some text when text <> "" -> Ok text
    | _ when !saw_terminal -> Ok ""
    | _ -> (
        let body =
          match split_headers_body response with
          | Some body -> body
          | None -> response
        in
            let* json =
              try Ok (Yojson.Safe.from_string (trim body))
              with Yojson.Json_error msg ->
                Error ("invalid response JSON: " ^ msg)
            in
            match get_object json "result" with
            | Some result_json -> (
                match get_string result_json "text" with
                | Some text when text <> "" -> Ok text
                | _ -> Error "response JSON missing result.text")
            | None -> (
                match get_object json "error" with
                | Some err_json -> (
                    match get_string err_json "message" with
                    | Some message -> Error message
                    | None -> Error "response JSON missing error.message")
                | None -> Error "response JSON missing result"))

type transport_health = {
  th_primary_path : string;
  th_queue_pressure : string;
  th_sse_sessions : int;
  th_websocket_sessions : int option;
  th_grpc_port : int option;
  th_events_dropped : int;
}

let require_object json key =
  match member key json with
  | `Assoc _ as obj -> Ok obj
  | `Null -> Error (Printf.sprintf "missing required field '%s'" key)
  | other ->
      Error
        (Printf.sprintf "field '%s' must be an object (received %s)" key
           (Json_util.kind_name other))

let decode_transport_health json =
  let ( let* ) = Result.bind in
  let* summary = require_object json "summary" in
  let* th_primary_path = require_string_field summary "primary_path" in
  let* th_queue_pressure = require_string_field summary "queue_pressure" in
  let* sse = require_object json "sse" in
  let* th_sse_sessions = require_int_field sse "sessions_total" in
  let* websocket = require_object json "websocket" in
  let* websocket_listening = require_bool websocket "listening" in
  (* A path that is not listening has no sessions to report. Reporting zero
     would read as "listening, nobody connected", which is a different fact. *)
  let* th_websocket_sessions =
    if websocket_listening then
      Result.map Option.some (require_int_field websocket "sessions")
    else Ok None
  in
  let* grpc = require_object json "grpc" in
  let* grpc_listening = require_bool grpc "listening" in
  let* th_grpc_port =
    if grpc_listening then Result.map Option.some (require_int_field grpc "port")
    else Ok None
  in
  let* th_events_dropped = require_int_field grpc "events_dropped" in
  Ok
    {
      th_primary_path;
      th_queue_pressure;
      th_sse_sessions;
      th_websocket_sessions;
      th_grpc_port;
      th_events_dropped;
    }
