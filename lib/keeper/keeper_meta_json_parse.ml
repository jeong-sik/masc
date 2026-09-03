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

let canonical_proactive_outcome_opt raw =
  let outcome = proactive_cycle_outcome_of_string raw in
  if String.equal raw (proactive_cycle_outcome_to_string outcome)
  then Some outcome
  else None
;;

let parse_proactive_outcome fields =
  let* raw = string_field fields "last_proactive_outcome" in
  match canonical_proactive_outcome_opt raw with
  | Some outcome -> Ok outcome
  | None -> invalidf "last_proactive_outcome has non-canonical value %S" raw
;;

type enum_field_repair =
  { field : string
  ; previous_value : string
  ; repaired_value : string
  }

(* Issue #28844: repair target for one non-canonical enumerated value.
   [None] means already canonical (no repair).  [Some repaired] is the
   canonical spelling of the recognized value when the field's [of_string]
   accepts [raw] — both parsers trim and lowercase, so a case/whitespace
   misspelling keeps the operator's intent.  Only a value the parser does
   not recognize at all falls back to the field's canonical default (the
   value the create path writes for a keeper that never exercised the
   corresponding machinery), which is the lossless reset. *)
let proactive_outcome_repair_value raw =
  match canonical_proactive_outcome_opt raw with
  | Some _ -> None
  | None ->
    (* [proactive_cycle_outcome_of_string] is total: unrecognized garbage
       lands on [Proactive_unknown], so a recognized misspelling is exactly
       a parse to any other variant.  A misspelled ["unknown"] is
       indistinguishable from garbage through the total parser and resets
       with it. *)
    (match proactive_cycle_outcome_of_string raw with
     | Proactive_unknown ->
       Some (proactive_cycle_outcome_to_string Proactive_never_started)
     | outcome -> Some (proactive_cycle_outcome_to_string outcome))
;;

(* Persisted enumerated fields repairable in place.  A field belongs here
   only when an unrecognized value has exactly one sane fallback; anything
   else keeps failing loud. *)
let repairable_enum_fields =
  [ "last_proactive_outcome", proactive_outcome_repair_value ]
;;

let repair_non_canonical_enum_fields json =
  match json with
  | `Assoc fields ->
    let repairs =
      List.filter_map
        (fun (field, repair_value) ->
           match List.assoc_opt field fields with
           | Some (`String raw) ->
             (match repair_value raw with
              | Some repaired_value ->
                Some { field; previous_value = raw; repaired_value }
              | None -> None)
           | Some _ | None -> None)
        repairable_enum_fields
    in
    (match repairs with
     | [] -> None
     | repairs ->
       let repaired_fields =
         List.map
           (fun (key, value) ->
              match
                List.find_opt
                  (fun repair -> String.equal repair.field key)
                  repairs
              with
              | Some repair -> key, `String repair.repaired_value
              | None -> key, value)
           fields
       in
       Some (`Assoc repaired_fields, repairs))
  | _ -> None
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

let parse_agent_core_env fields =
  let* value = required_field fields "agent_core_env" in
  match value with
  | `Assoc env_fields ->
    (match find_duplicate env_fields with
     | Some key -> invalidf "agent_core_env has duplicate key %S" key
     | None ->
       let rec collect acc = function
         | [] -> Ok (List.rev acc)
         | (key, `String value) :: rest -> collect ((key, value) :: acc) rest
         | (key, other) :: _ ->
           invalidf
             "agent_core_env.%s must be a string, got %s"
             key
             (Json_util.kind_name other)
       in
       collect [] env_fields)
  | other -> invalidf "agent_core_env must be an object, got %s" (Json_util.kind_name other)
;;

let decode_current_meta fields =
  let* schema = string_field fields "schema" in
  let* name = string_field fields "name" in
  let* instructions = string_field fields "instructions" in
  let* trace_id_raw = string_field fields "trace_id" in
  let* trace_id = parse_trace_id trace_id_raw in
  let* trace_history = parse_trace_history fields in
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
  let* usage_cursor =
    let* json = required_field fields "usage_cursor" in
    match json with
    | `Null -> Ok None
    | json ->
      (match Keeper_usage_resolution.cursor_of_json json with
       | Ok value -> Ok (Some value)
       | Error detail -> invalidf "usage_cursor: %s" detail)
  in
  let* last_usage_resolution =
    let* json = required_field fields "last_usage_resolution" in
    match json with
    | `Null -> Ok None
    | json ->
      (match Keeper_usage_resolution.of_json json with
       | Ok value -> Ok (Some value)
       | Error detail -> invalidf "last_usage_resolution: %s" detail)
  in
  let* last_latency_ms = int_field fields "last_latency_ms" in
  let* proactive_count_total = int_field fields "proactive_count_total" in
  let* last_proactive_ts = float_field fields "last_proactive_ts" in
  let* proactive_visible_count_total = int_field fields "proactive_visible_count_total" in
  let* last_visible_proactive_ts = float_field fields "last_visible_proactive_ts" in
  let* last_proactive_outcome = parse_proactive_outcome fields in
  let* last_proactive_reason = string_field fields "last_proactive_reason" in
  let* last_proactive_preview = string_field fields "last_proactive_preview" in
  let* message_scope_ack_id = nullable_string_field fields "message_scope_ack_id" in
  let* last_runtime_attempt = parse_last_runtime_attempt fields in
  let* paused = bool_field fields "paused" in
  let* latched_reason = parse_latched_reason fields in
  let* current_task_id = parse_current_task_id fields in
  let* keeper_id = parse_keeper_id fields in
  let* agent_core_env = parse_agent_core_env fields in
  (* Kept now that the reader fails open: the exact-field check cannot see a
     format whose field names stayed the same while their meaning changed, and
     rejecting costs a reset rather than a dead keeper. *)
  if not (String.equal schema "masc.keeper_meta.v2")
  then invalidf "unsupported schema: %S" schema
  else if not (validate_name name)
  then invalidf "name is invalid: %S" name
  (* Generation is the lifecycle fencing counter, so zero is not a valid
     persisted value: it is what an unstamped or reset row looks like. This
     decoder replaces [parse_required_positive_generation], which enforced the
     same bound on every read, so the bound is carried here rather than
     relaxed. Absence is already rejected because [int_field] goes through
     [required_field]. *)
  else if not (validate_name (Keeper_id.Trace_id.to_string trace_id))
  then invalidf "trace_id is invalid: %S" trace_id_raw
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
    let proactive_rt : proactive_runtime =
      { count_total = proactive_count_total
      ; last_ts = last_proactive_ts
      ; visible_count_total = proactive_visible_count_total
      ; last_visible_ts = last_visible_proactive_ts
      ; last_outcome = last_proactive_outcome
      ; last_reason = last_proactive_reason
      ; last_preview = last_proactive_preview
      }
    in
    let runtime : agent_runtime_state =
      { usage
      ; usage_cursor
      ; last_usage_resolution
      ; proactive_rt
      ; trace_id
      ; trace_history
      ; last_handoff_ts
      ; message_scope_ack_id
      ; last_runtime_attempt
      }
    in
    (* The eleven config fields below are placeholders, not decoded values.
       TOML owns them and [Keeper_meta_contract.effective_meta_of_profile_defaults]
       overlays the real ones on the way out, so [meta_to_json] never writes
       them and this decoder has nothing to read back. A caller that writes
       [{ meta with autoboot_enabled = false }] through [write_keeper_meta]
       compiles, stores nothing and reads back [true] (#27357). Splitting
       config out of this record is the fix; until then the round-trip
       contract is pinned by test_keeper_meta_config_not_durable. *)
    (* A placeholder for the TOML-owned profile, never a stored value. The
       old claim that no path reads it as authority was disproved: the
       post-tool observer adopted durable meta whole and dispatched a
       microvm keeper's Execute to the host docker daemon (#31178 drift,
       observer site, 2026-09-01), and that failure is open — a dispatch to
       a daemon that may be down — not closed. The contract: any adoption
       of durable meta back into a live turn goes through
       [Keeper_meta_contract.effective_meta_of_profile_defaults] and keeps
       the admitted meta on overlay error. Reading this field as authority
       is a bug regardless of the value being a safe backend. *)
    let sandbox_profile = Docker in
    let meta : keeper_meta =
      { id = None
      ; name
      ; instructions
      ; sandbox_profile
      ; sandbox_image = None
      (* Not derived from the placeholder above: deriving one placeholder from
         another gave this field [Network_none], and a profile resolved later
         as [remote_ssh] rejects that outright. [Network_inherit] is the value
         every profile accepts, which is what a placeholder has to be. *)
      ; network_mode = Keeper_types_profile.Network_inherit
      (* A placeholder for the same reason the profile above is one: which
         microVM runtime serves a keeper is TOML-owned, and durable meta is
         not its authority. [None] rather than a runtime because there is no
         value here that is safe to dispatch on — a stored name would be the
         drift the comment above describes, in a second field. *)
      ; microvm_backend = None
      ; mention_targets = []
      ; proactive = { enabled = default_proactive_enabled }
      ; always_allow = None
      ; created_at
      ; updated_at
      ; paused
      ; latched_reason
      ; autoboot_enabled = true
      ; current_task_id
      ; max_context_override = None
      ; telemetry_feedback_enabled = None
      ; telemetry_feedback_window_hours = None
      ; runtime
      ; agent_core_env
      ; keeper_id
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
       | Ok meta -> Ok meta)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> invalidf "decoder raised: %s" (Printexc.to_string exn)
;;
