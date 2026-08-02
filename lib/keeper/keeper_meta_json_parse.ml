(** Exact current-schema Keeper meta JSON parser. *)

open Keeper_types_profile
open Keeper_meta_contract
open Keeper_meta_json_current_schema

let ( let* ) = Result.bind

let invalidf format =
  Printf.ksprintf
    (fun detail ->
       Error
         (Printf.sprintf
            "invalid current keeper meta: %s; runtime reset required"
            detail))
    format
;;

let required_field fields name =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> invalidf "missing required field %s" name
;;

let string_field fields name =
  let* value = required_field fields name in
  match value with
  | `String value -> Ok value
  | other -> invalidf "field %s must be a string, got %s" name (Json_util.kind_name other)
;;

let int_field fields name =
  let* value = required_field fields name in
  match value with
  | `Int value -> Ok value
  | other -> invalidf "field %s must be an integer, got %s" name (Json_util.kind_name other)
;;

(* RFC-0357 §3.3: absence-tolerated only for fields listed in
   [Keeper_meta_json_current_schema.genesis_defaulted_field_names]. An absent
   field is a pre-RFC meta and decodes as the genesis value; a PRESENT
   malformed or negative value still fails the decode — corruption must not
   silently rewind an edge clock. *)
let genesis_int_field fields name ~genesis =
  match List.assoc_opt name fields with
  | None -> Ok genesis
  | Some (`Int value) ->
    if value >= 0
    then Ok value
    else invalidf "field %s must be nonnegative, got %d" name value
  | Some other ->
    invalidf "field %s must be an integer, got %s" name (Json_util.kind_name other)
;;

let float_field fields name =
  let* value = required_field fields name in
  let parsed =
    match value with
    | `Float value -> Some value
    | `Int value -> Some (float_of_int value)
    | _ -> None
  in
  match parsed with
  | Some value when Float.is_finite value -> Ok value
  | Some _ -> invalidf "field %s must be finite" name
  | None -> invalidf "field %s must be a number, got %s" name (Json_util.kind_name value)
;;

let bool_field fields name =
  let* value = required_field fields name in
  match value with
  | `Bool value -> Ok value
  | other -> invalidf "field %s must be a boolean, got %s" name (Json_util.kind_name other)
;;

let nullable_string_field fields name =
  let* value = required_field fields name in
  match value with
  | `Null -> Ok None
  | `String value -> Ok (Some value)
  | other ->
    invalidf "field %s must be a string or null, got %s" name (Json_util.kind_name other)
;;

let string_list_field fields name =
  let* value = required_field fields name in
  match value with
  | `List values ->
    let rec collect acc = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest -> collect (value :: acc) rest
      | other :: _ ->
        invalidf
          "field %s must contain only strings, got %s"
          name
          (Json_util.kind_name other)
    in
    collect [] values
  | other -> invalidf "field %s must be an array, got %s" name (Json_util.kind_name other)
;;

let find_duplicate fields =
  let rec loop seen = function
    | [] -> None
    | (key, _) :: rest ->
      if List.mem key seen then Some key else loop (key :: seen) rest
  in
  loop [] fields
;;

let require_exact_fields ~context expected fields =
  match find_duplicate fields with
  | Some key -> invalidf "%s has duplicate field %s" context key
  | None ->
    let present = List.map fst fields in
    let missing = List.filter (fun key -> not (List.mem key present)) expected in
    let extra = List.filter (fun key -> not (List.mem key expected)) present in
    if missing <> []
    then invalidf "%s is missing fields: %s" context (String.concat ", " missing)
    else if extra <> []
    then invalidf "%s has unknown fields: %s" context (String.concat ", " extra)
    else Ok ()
;;

let parse_trace_id raw =
  if String.trim raw = ""
  then invalidf "trace_id must not be empty"
  else
    match Keeper_id.Trace_id.of_string raw with
    | Ok trace_id -> Ok trace_id
    | Error detail -> invalidf "trace_id is invalid: %s" detail
;;

let parse_trace_history fields =
  let* history = string_list_field fields "trace_history" in
  match List.find_opt (fun trace_id -> not (validate_name trace_id)) history with
  | None -> Ok history
  | Some trace_id -> invalidf "trace_history contains invalid trace id %S" trace_id
;;

let parse_multimodal_policy fields =
  let* raw = string_field fields "multimodal_policy" in
  match multimodal_policy_of_string raw with
  | Some policy when String.equal raw (multimodal_policy_to_string policy) -> Ok policy
  | Some _ | None -> invalidf "multimodal_policy has non-canonical value %S" raw
;;

let parse_proactive_outcome fields =
  let* raw = string_field fields "last_proactive_outcome" in
  let outcome = proactive_cycle_outcome_of_string raw in
  if String.equal raw (proactive_cycle_outcome_to_string outcome)
  then Ok outcome
  else invalidf "last_proactive_outcome has non-canonical value %S" raw
;;

let parse_last_blocker fields =
  let* value = required_field fields "last_blocker" in
  match value with
  | `Null -> Ok None
  | `Assoc blocker_fields ->
    let* () =
      require_exact_fields
        ~context:"last_blocker"
        [ "klass"; "detail" ]
        blocker_fields
    in
    let* detail = string_field blocker_fields "detail" in
    let* klass_json = required_field blocker_fields "klass" in
    let* klass =
      match klass_json with
      | `String label ->
        (match blocker_class_of_serialized_string label with
         | Some (Runtime_exhausted _) ->
           invalidf "last_blocker.klass runtime_exhausted requires a reason object"
         | Some klass -> Ok klass
         | None -> invalidf "last_blocker.klass has unknown value %S" label)
      | `Assoc klass_fields ->
        let* () =
          require_exact_fields
            ~context:"last_blocker.klass"
            [ "name"; "reason" ]
            klass_fields
        in
        let* name = string_field klass_fields "name" in
        if not (String.equal name "runtime_exhausted")
        then invalidf "last_blocker.klass has unknown object name %S" name
        else
          let* reason_json = required_field klass_fields "reason" in
          (match runtime_exhaustion_reason_of_json reason_json with
           | Some reason
             when Yojson.Safe.equal
                    reason_json
                    (runtime_exhaustion_reason_to_json reason) ->
             Ok (Runtime_exhausted reason)
           | Some _ | None ->
             invalidf "last_blocker.klass.reason is not the current exact shape")
      | other ->
        invalidf
          "last_blocker.klass must be a string or object, got %s"
          (Json_util.kind_name other)
    in
    Ok (Some { klass; detail })
  | other ->
    invalidf
      "field last_blocker must be an object or null, got %s"
      (Json_util.kind_name other)
;;

let parse_runtime_attempt_outcome value =
  match value with
  | `Assoc fields ->
    let* kind = string_field fields "kind" in
    (match kind with
     | "success" ->
       let* () =
         require_exact_fields ~context:"last_runtime_attempt.outcome" [ "kind" ] fields
       in
       Ok `Success
     | "failure" ->
       let* () =
         require_exact_fields
           ~context:"last_runtime_attempt.outcome"
           [ "kind"; "message" ]
           fields
       in
       let* message = string_field fields "message" in
       Ok (`Failure message)
     | other -> invalidf "last_runtime_attempt.outcome has unknown kind %S" other)
  | other ->
    invalidf
      "last_runtime_attempt.outcome must be an object, got %s"
      (Json_util.kind_name other)
;;

let parse_last_runtime_attempt fields =
  let* value = required_field fields "last_runtime_attempt" in
  match value with
  | `Null -> Ok None
  | `Assoc attempt_fields ->
    let* () =
      require_exact_fields
        ~context:"last_runtime_attempt"
        [ "provider_id"; "http_status"; "outcome"; "timestamp" ]
        attempt_fields
    in
    let* provider_id = string_field attempt_fields "provider_id" in
    let* http_status_json = required_field attempt_fields "http_status" in
    let* http_status =
      match http_status_json with
      | `Null -> Ok None
      | `Int status -> Ok (Some status)
      | other ->
        invalidf
          "last_runtime_attempt.http_status must be an integer or null, got %s"
          (Json_util.kind_name other)
    in
    let* outcome_json = required_field attempt_fields "outcome" in
    let* outcome = parse_runtime_attempt_outcome outcome_json in
    let* timestamp = float_field attempt_fields "timestamp" in
    let attempt : runtime_attempt_record =
      { provider_id; http_status; outcome; timestamp }
    in
    Ok (Some attempt)
  | other ->
    invalidf
      "field last_runtime_attempt must be an object or null, got %s"
      (Json_util.kind_name other)
;;

let parse_latched_reason fields =
  let* value = required_field fields "latched_reason" in
  match value with
  | `Null -> Ok None
  | reason_json ->
    (match Keeper_latched_reason.Stable.of_yojson reason_json with
     | Ok reason -> Ok (Some reason)
     | Error detail -> invalidf "latched_reason is invalid: %s" detail)
;;

let parse_current_task_id fields =
  let* raw = nullable_string_field fields "current_task_id" in
  match raw with
  | None -> Ok None
  | Some raw ->
    (match Keeper_id.Task_id.of_string raw with
     | Ok task_id -> Ok (Some task_id)
     | Error detail -> invalidf "current_task_id is invalid: %s" detail)
;;

let parse_keeper_id fields =
  let* value = required_field fields "keeper_id" in
  match value with
  | `Null -> Ok None
  | `String _ as json ->
    (match Keeper_id.uid_of_yojson json with
     | Ok keeper_id -> Ok (Some keeper_id)
     | Error detail -> invalidf "keeper_id is invalid: %s" detail)
  | other ->
    invalidf "keeper_id must be a string or null, got %s" (Json_util.kind_name other)
;;

let parse_oas_env fields =
  let* value = required_field fields "oas_env" in
  match value with
  | `Assoc env_fields ->
    (match find_duplicate env_fields with
     | Some key -> invalidf "oas_env has duplicate key %S" key
     | None ->
       let rec collect acc = function
         | [] -> Ok (List.rev acc)
         | (key, `String value) :: rest -> collect ((key, value) :: acc) rest
         | (key, other) :: _ ->
           invalidf
             "oas_env.%s must be a string, got %s"
             key
             (Json_util.kind_name other)
       in
       collect [] env_fields)
  | other -> invalidf "oas_env must be an object, got %s" (Json_util.kind_name other)
;;

let decode_current_meta fields =
  let* name = string_field fields "name" in
  let* agent_name = string_field fields "agent_name" in
  let* persona = nullable_string_field fields "persona" in
  let* instructions = string_field fields "instructions" in
  let* trace_id_raw = string_field fields "trace_id" in
  let* trace_id = parse_trace_id trace_id_raw in
  let* multimodal_policy = parse_multimodal_policy fields in
  let* trace_history = parse_trace_history fields in
  let* nonce = int_field fields "generation" in
  let* last_handoff_ts = float_field fields "last_handoff_ts" in
  let* created_at = string_field fields "created_at" in
  let* updated_at = string_field fields "updated_at" in
  let* total_turns = int_field fields "total_turns" in
  let* total_input_tokens = int_field fields "total_input_tokens" in
  let* total_output_tokens = int_field fields "total_output_tokens" in
  let* total_tokens = int_field fields "total_tokens" in
  let* total_cost_usd = float_field fields "total_cost_usd" in
  let* last_turn_ts = float_field fields "last_turn_ts" in
  let* last_input_tokens = int_field fields "last_input_tokens" in
  let* last_output_tokens = int_field fields "last_output_tokens" in
  let* last_total_tokens = int_field fields "last_total_tokens" in
  let* last_latency_ms = int_field fields "last_latency_ms" in
  let* compaction_count = int_field fields "compaction_count" in
  let* last_compaction_ts = float_field fields "last_compaction_ts" in
  let* last_compaction_before_tokens = int_field fields "last_compaction_before_tokens" in
  let* last_compaction_after_tokens = int_field fields "last_compaction_after_tokens" in
  let* proactive_count_total = int_field fields "proactive_count_total" in
  let* last_proactive_ts = float_field fields "last_proactive_ts" in
  let* proactive_visible_count_total = int_field fields "proactive_visible_count_total" in
  let* last_visible_proactive_ts = float_field fields "last_visible_proactive_ts" in
  let* last_proactive_outcome = parse_proactive_outcome fields in
  let* last_proactive_reason = string_field fields "last_proactive_reason" in
  let* last_proactive_preview = string_field fields "last_proactive_preview" in
  let* consecutive_noop_count = int_field fields "consecutive_noop_count" in
  let* last_consumed_backlog_revision =
    genesis_int_field fields "last_consumed_backlog_revision" ~genesis:0
  in
  let* last_compaction_check_ts = float_field fields "last_compaction_check_ts" in
  let* last_compaction_decision_raw = string_field fields "last_compaction_decision" in
  let* active_goal_ids = string_list_field fields "active_goal_ids" in
  let* last_autonomous_action_at = string_field fields "last_autonomous_action_at" in
  let* autonomous_action_count = int_field fields "autonomous_action_count" in
  let* autonomous_turn_count = int_field fields "autonomous_turn_count" in
  let* autonomous_text_turn_count = int_field fields "autonomous_text_turn_count" in
  let* autonomous_tool_turn_count = int_field fields "autonomous_tool_turn_count" in
  let* board_reactive_turn_count = int_field fields "board_reactive_turn_count" in
  let* mention_reactive_turn_count = int_field fields "mention_reactive_turn_count" in
  let* noop_turn_count = int_field fields "noop_turn_count" in
  let* message_scope_ack_id = nullable_string_field fields "message_scope_ack_id" in
  let* last_blocker = parse_last_blocker fields in
  let* last_runtime_attempt = parse_last_runtime_attempt fields in
  let* paused = bool_field fields "paused" in
  let* latched_reason = parse_latched_reason fields in
  let* current_task_id = parse_current_task_id fields in
  let* keeper_id = parse_keeper_id fields in
  let* oas_env = parse_oas_env fields in
  let* meta_version = int_field fields "meta_version" in
  if not (validate_name name)
  then invalidf "name is invalid: %S" name
  (* Generation is the lifecycle fencing counter, so zero is not a valid
     persisted value: it is what an unstamped or reset row looks like. This
     decoder replaces [parse_required_positive_generation], which enforced the
     same bound on every read, so the bound is carried here rather than
     relaxed. Absence is already rejected because [int_field] goes through
     [required_field]. *)
  else if nonce < 1
  then invalidf "persisted keeper generation must be a positive integer"
  else if
    not
      (String.equal
         agent_name
         (Keeper_identity.keeper_agent_name name))
  then invalidf "agent_name does not match canonical keeper identity"
  else if not (validate_name (Keeper_id.Trace_id.to_string trace_id))
  then invalidf "trace_id is invalid: %S" trace_id_raw
  else if meta_version < 0
  then invalidf "meta_version must be nonnegative"
  else if meta_version = max_int
  then invalidf "meta_version must remain incrementable"
  else
    let usage : usage_metrics =
      { total_turns
      ; total_input_tokens
      ; total_output_tokens
      ; total_tokens
      ; total_cost_usd
      ; last_turn_ts
      ; last_input_tokens
      ; last_output_tokens
      ; last_total_tokens
      ; last_usage_reported_at = None
      ; last_latency_ms
      }
    in
    let compaction_rt : compaction_runtime =
      { count = compaction_count
      ; last_ts = last_compaction_ts
      ; last_before_tokens = last_compaction_before_tokens
      ; last_after_tokens = last_compaction_after_tokens
      ; last_check_ts = last_compaction_check_ts
      ; last_decision = compaction_runtime_decision_of_string last_compaction_decision_raw
      }
    in
    let proactive_rt : proactive_runtime =
      { count_total = proactive_count_total
      ; last_ts = last_proactive_ts
      ; visible_count_total = proactive_visible_count_total
      ; last_visible_ts = last_visible_proactive_ts
      ; last_outcome = last_proactive_outcome
      ; last_reason = last_proactive_reason
      ; last_preview = last_proactive_preview
      ; consecutive_noop_count
      ; last_consumed_backlog_revision
      }
    in
    let runtime : agent_runtime_state =
      { usage
      ; compaction_rt
      ; proactive_rt
      ; nonce
      ; trace_id
      ; trace_history
      ; last_handoff_ts
      ; last_autonomous_action_at
      ; autonomous_action_count
      ; autonomous_turn_count
      ; autonomous_text_turn_count
      ; autonomous_tool_turn_count
      ; board_reactive_turn_count
      ; mention_reactive_turn_count
      ; noop_turn_count
      ; message_scope_ack_id
      ; last_blocker
      ; last_runtime_attempt
      }
    in
    let sandbox_profile = default_sandbox_profile in
    let meta : keeper_meta =
      { id = None
      ; name
      ; agent_name
      ; persona
      ; instructions
      ; sandbox_profile
      ; sandbox_image = None
      ; network_mode = default_network_mode_for_profile sandbox_profile
      ; allowed_paths = []
      ; mention_targets = []
      ; proactive = { enabled = default_proactive_enabled }
      ; multimodal_policy
      ; always_allow = None
      ; created_at
      ; updated_at
      ; active_goal_ids
      ; paused
      ; latched_reason
      ; autoboot_enabled = true
      ; current_task_id
      ; max_context_override = None
      ; telemetry_feedback_enabled = None
      ; telemetry_feedback_window_hours = None
      ; runtime
      ; oas_env
      ; keeper_id
      ; meta_version
      }
    in
    Ok meta
;;

let meta_of_json json =
  try
    match validate_current_object json with
    | Error error -> Error (validation_error_detail error)
    | Ok fields ->
      (match decode_current_meta fields with
       | Error _ as error -> error
       | Ok meta ->
         (match Keeper_meta_contract.terminal_latch_pause_violation meta with
          | None -> Ok meta
          | Some detail -> invalidf "%s" detail))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> invalidf "decoder raised: %s" (Printexc.to_string exn)
;;
