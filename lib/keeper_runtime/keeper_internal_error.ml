(** Keeper_internal_error — the [masc_internal_error] ADT, its JSON codec, and the reverse-direction
    SDK envelope parser.

    This is the structured *typed envelope* carried across the
    [Agent_sdk.Error.Internal _] boundary for keeper turn failures.  It is the
    re-homed successor of the deleted runtime dispatch error helpers
    (RFC-0206 runtime purge): the dispatch engine that constructed many of these variants
    is gone, but the envelope itself outlives it — provider/turn failures still
    need structured carrying.

    The originating-runtime field is now a plain [string] (the former
    [Runtime_id.t] type is deleted).  JSON keys and the per-kind label
    strings are preserved verbatim because the operator dashboard
    ([dashboard/src]) parses [kind] / [runtime_id] off the wire. *)

(* The originating runtime id is a plain string.  Kept as a named
   identity helper so the JSON codec below reads identically to its pre-purge
   form (each variant serialises the id under the historical ["runtime_id"]
   key the dashboard still parses). *)
let runtime_id_to_string (s : string) = s

(* Canonical wire kind for the typed [Capacity_backpressure] envelope.  The
   producer codec, receipt terminal projection, and consumer decoder share
   this value so recoverability cannot drift through duplicated literals. *)
let capacity_backpressure_kind = "capacity_backpressure"

type provider_rejection = {
  provider_label : string;
  reason : string;
}

type capacity_backpressure_source =
  | Provider_capacity
  | Client_capacity
  | Runtime_slot

let capacity_backpressure_source_to_string = function
  | Provider_capacity -> "provider_capacity"
  | Client_capacity -> "client_capacity"
  | Runtime_slot -> "runtime_slot"

let capacity_backpressure_source_of_string = function
  | "provider_capacity" -> Some Provider_capacity
  | "client_capacity" -> Some Client_capacity
  | "runtime_slot" -> Some Runtime_slot
  | _ -> None

(** Provider-supplied retry-after hint for capacity backpressure. *)
type capacity_retry_after =
  | Explicit of float
  | No_retry_hint

(** Legacy cause carried by persisted [Capacity_backpressure] envelopes. *)
type provider_cooldown_cause =
  | Cooldown_provider_capacity
  | Cooldown_soft_rate_limited
  | Cooldown_server_error
  | Cooldown_hard_quota
  | Cooldown_terminal_failure
  | Cooldown_provider_error
  | Cooldown_rejected

let provider_cooldown_cause_to_string = function
  | Cooldown_provider_capacity -> "provider_capacity"
  | Cooldown_soft_rate_limited -> "soft_rate_limited"
  | Cooldown_server_error -> "server_error"
  | Cooldown_hard_quota -> "hard_quota"
  | Cooldown_terminal_failure -> "terminal_failure"
  | Cooldown_provider_error -> "provider_error"
  | Cooldown_rejected -> "rejected"

let provider_cooldown_cause_of_string = function
  | "provider_capacity" -> Some Cooldown_provider_capacity
  | "soft_rate_limited" -> Some Cooldown_soft_rate_limited
  | "server_error" -> Some Cooldown_server_error
  | "hard_quota" -> Some Cooldown_hard_quota
  | "terminal_failure" -> Some Cooldown_terminal_failure
  | "provider_error" -> Some Cooldown_provider_error
  | "rejected" -> Some Cooldown_rejected
  | _ -> None

(** [true] when waiting out the cooldown cannot resolve the cause: the next
    attempt hits the same deterministic condition (config/build error, depleted
    balance, structural provider failure, rejected output).  Transient causes
    (provider capacity, HTTP 429, HTTP 5xx) are expected to recover, so a
    cooldown block armed by them stays auto-recoverable.  A deterministic cause
    must instead flow into the crash/pause escalation path so the keeper stops
    oscillating.  #23438. *)
let provider_cooldown_cause_is_deterministic = function
  | Cooldown_hard_quota
  | Cooldown_terminal_failure
  | Cooldown_provider_error
  | Cooldown_rejected -> true
  | Cooldown_provider_capacity
  | Cooldown_soft_rate_limited
  | Cooldown_server_error -> false

type runtime_exhaustion_reason =
  | Connection_refused
  | Dns_failure
  | No_providers_available
  | All_providers_failed
  | Candidates_filtered_after_cycles
  | Max_turns_exceeded
  | Session_conflict
  | Structural_attempt_timeout of { detail : string }
  | Capacity_exhausted
  | Other_detail of string

let runtime_exhaustion_reason_retryable = function
  | Candidates_filtered_after_cycles | Max_turns_exceeded | Capacity_exhausted ->
    true
  | Connection_refused | Dns_failure | No_providers_available | All_providers_failed ->
    true
  | Structural_attempt_timeout _ -> true
  | Session_conflict | Other_detail _ -> false

let runtime_exhaustion_label_payload_max_bytes = 200

let runtime_exhaustion_label_payload detail =
  let collapsed =
    detail |> String_util.query_tokens |> String.concat " " |> String.trim
  in
  String_util.utf8_safe
    ~max_bytes:(runtime_exhaustion_label_payload_max_bytes + 3)
    ~suffix:"..."
    collapsed
  |> String_util.to_string

(** Human-readable label for {!summary_of_masc_internal_error} and log
    lines. Distinct from {!runtime_exhaustion_reason_to_json}'s wire tags:
    this carries the [detail]/[message] payload inline so an operator does
    not need to cross-reference the JSON-encoded event. *)
let runtime_exhaustion_reason_to_label = function
  | Connection_refused -> "connection_refused"
  | Dns_failure -> "dns_failure"
  | No_providers_available -> "no_providers_available"
  | All_providers_failed -> "all_providers_failed"
  | Candidates_filtered_after_cycles -> "candidates_filtered_after_cycles"
  | Max_turns_exceeded -> "max_turns_exceeded"
  | Session_conflict -> "session_conflict"
  | Structural_attempt_timeout { detail } ->
    Printf.sprintf "structural_attempt_timeout(%s)"
      (runtime_exhaustion_label_payload detail)
  | Capacity_exhausted -> "capacity_exhausted"
  | Other_detail detail ->
    Printf.sprintf "other(%s)" (runtime_exhaustion_label_payload detail)

let runtime_exhaustion_reason_to_json = function
  | Connection_refused -> `String "connection_refused"
  | Dns_failure -> `String "dns_failure"
  | No_providers_available -> `String "no_providers_available"
  | All_providers_failed -> `String "all_providers_failed"
  | Candidates_filtered_after_cycles -> `String "candidates_filtered_after_cycles"
  | Max_turns_exceeded -> `String "max_turns_exceeded"
  | Session_conflict -> `String "session_conflict"
  | Structural_attempt_timeout { detail } ->
    `Assoc [ "tag", `String "structural_attempt_timeout"; "detail", `String detail ]
  | Capacity_exhausted -> `String "capacity_exhausted"
  | Other_detail msg -> `Assoc [ "tag", `String "other_detail"; "message", `String msg ]

let runtime_exhaustion_reason_of_json = function
  | `String "connection_refused" -> Some Connection_refused
  | `String "dns_failure" -> Some Dns_failure
  | `String "no_providers_available" -> Some No_providers_available
  | `String "all_providers_failed" -> Some All_providers_failed
  | `String "candidates_filtered_after_cycles" -> Some Candidates_filtered_after_cycles
  | `String "max_turns_exceeded" -> Some Max_turns_exceeded
  | `String "session_conflict" -> Some Session_conflict
  | `String "capacity_exhausted" -> Some Capacity_exhausted
  | `Assoc fields ->
    (match List.assoc_opt "tag" fields with
     | Some (`String "structural_attempt_timeout") ->
       (match List.assoc_opt "detail" fields with
         | Some (`String detail) -> Some (Structural_attempt_timeout { detail })
         | _ -> None)
     | Some (`String "other_detail") ->
       (match List.assoc_opt "message" fields with
         | Some (`String msg) -> Some (Other_detail msg)
         | _ -> None)
     | _ -> None)
  | _ -> None

type accept_rejection_kind =
  | Accept_no_usable_progress
  | Accept_predicate_rejected

let accept_rejection_kind_to_string = function
  | Accept_no_usable_progress -> "no_usable_progress"
  | Accept_predicate_rejected -> "predicate_rejected"
;;

let accept_rejection_kind_of_string = function
  | "no_usable_progress" -> Some Accept_no_usable_progress
  | "predicate_rejected" -> Some Accept_predicate_rejected
  | _ -> None
;;

type accept_response_shape =
  | Accept_response_empty
  | Accept_response_thinking_only
  | Accept_response_blank_text_only
  | Accept_response_tool_result_only
  | Accept_response_media_only
  | Accept_response_mixed_without_deliverable_content
  | Accept_response_has_deliverable_content

let accept_response_shape_to_string = function
  | Accept_response_empty -> "empty"
  | Accept_response_thinking_only -> "thinking_only"
  | Accept_response_blank_text_only -> "blank_text_only"
  | Accept_response_tool_result_only -> "tool_result_only"
  | Accept_response_media_only -> "media_only"
  | Accept_response_mixed_without_deliverable_content ->
    "mixed_without_deliverable_content"
  | Accept_response_has_deliverable_content -> "has_deliverable_content"
;;

let accept_response_shape_of_string = function
  | "empty" -> Some Accept_response_empty
  | "thinking_only" -> Some Accept_response_thinking_only
  | "blank_text_only" -> Some Accept_response_blank_text_only
  | "tool_result_only" -> Some Accept_response_tool_result_only
  | "media_only" -> Some Accept_response_media_only
  | "mixed_without_deliverable_content" ->
    Some Accept_response_mixed_without_deliverable_content
  | "has_deliverable_content" -> Some Accept_response_has_deliverable_content
  | _ -> None
;;

let accept_response_shape_of_agent_sdk = function
  | Agent_sdk.Response_shape.Empty -> Accept_response_empty
  | Agent_sdk.Response_shape.Thinking_only -> Accept_response_thinking_only
  | Agent_sdk.Response_shape.Blank_text_only -> Accept_response_blank_text_only
  | Agent_sdk.Response_shape.Tool_result_only -> Accept_response_tool_result_only
  | Agent_sdk.Response_shape.Media_only -> Accept_response_media_only
  | Agent_sdk.Response_shape.Mixed_without_deliverable_content ->
    Accept_response_mixed_without_deliverable_content
  | Agent_sdk.Response_shape.Has_deliverable_content ->
    Accept_response_has_deliverable_content
;;

type masc_internal_error =
  | Runtime_exhausted of {
      runtime_id : string;
      reason : runtime_exhaustion_reason;
    }
  | Capacity_backpressure of {
      runtime_id : string;
      source : capacity_backpressure_source;
      detail : string;
      retry_after : capacity_retry_after;
      cooldown_cause : provider_cooldown_cause option;
      (* [Some cause] iff this is a pre-dispatch provider-health cooldown block
         (the arming failure's cause).  [None] for genuine capacity backpressure
         surfaced from an upstream capacity-exhaustion signal.  #23438. *)
    }
  | Resumable_cli_session of {
      runtime_id : string;
      detail : string;
      exit_code : int option;
    }
  | Accept_rejected of {
      scope : string;
      model : string option;
      reason_kind : accept_rejection_kind option;
      response_shape : accept_response_shape option;
      (* RFC-0271 §4.5: typed provider stop_reason for the rejected response.
         [MaxTokens] on an empty/thinking_only shape marks a truncation (the
         shared output budget was exhausted, most often by thinking) and must be
         distinguished from a clean [EndTurn] no-progress terminal — OAS gates
         its own [ended_without_deliverable_content] on [EndTurn] for exactly
         this reason. Groundwork only in this slice: threaded and serialized,
         not yet consumed by classification (§4.5 slices 2-3). *)
      stop_reason : Agent_sdk.Types.stop_reason option;
      reason : string;
    }
  | Turn_timeout of {
      elapsed_sec : float;
    }
  | Provider_timeout of {
      budget_sec : float;
      keeper_turn_timeout_sec : float;
      estimated_input_tokens : int;
      source : string;
      remaining_turn_budget_sec : float option;
      min_required_sec : float;
      phase : string;
    }
  | Internal_unhandled_exception of {
      site : string;
      exn_repr : string;
      transport_error_kind : Llm_provider.Http_client.network_error_kind option;
    }
  | Internal_bridge_exception of {
      caller : string;
      exn_repr : string;
    }
  | Internal_contract_rejected of {
      reason : string;
    }
  | Receipt_persistence_failed of {
      detail : string;
    }

let masc_internal_error_prefix = "[masc_oas_error] "
let runtime_runner_execute_site = "runtime_runner.execute"

(* #9933: a keeper [blocker_info] detail string may carry a structured
   [masc_oas_error] JSON payload — [masc_internal_error_prefix] above,
   possibly wrapped by Agent_sdk.Error.to_string's "Internal error: ".
   Truncating it at the narrative budget slices the JSON mid-key, so
   downstream consumers (dashboard, retry classifier, log search) lose the
   diagnostic fields (budget_sec, source, …). [cap_blocker_detail] keeps a
   payload that begins with the prefix up to
   [blocker_detail_structured_max_chars] and truncates plain narrative text
   to [blocker_detail_narrative_max_chars]. Idempotent. Applied where the
   runtime builds last_blocker.detail
   (keeper_unified_metrics_failure). *)
let blocker_detail_narrative_max_chars = 200

(* ~2000 chars fits a Yojson-encoded masc_internal_error record of any
   current variant plus the wrapping prefix, with headroom. Past this the
   payload is pathological and we cap rather than store unbounded blobs. *)
let blocker_detail_structured_max_chars = 2000

let masc_oas_error_bare_prefix = String.trim masc_internal_error_prefix
let masc_oas_error_wrapped_prefix = "Internal error: " ^ masc_oas_error_bare_prefix

let has_masc_oas_error_prefix (s : string) : bool =
  let starts_with prefix =
    let pl = String.length prefix in
    String.length s >= pl && String.sub s 0 pl = prefix
  in
  starts_with masc_oas_error_bare_prefix || starts_with masc_oas_error_wrapped_prefix

let cap_blocker_detail (s : string) : string =
  (* +3 bytes of headroom for the "…" ellipsis suffix. *)
  let truncate ~max_chars s =
    String_util.utf8_safe ~max_bytes:(max_chars + 3) ~suffix:"…" s
    |> String_util.to_string
  in
  if has_masc_oas_error_prefix (String.trim s) then
    if String.length s <= blocker_detail_structured_max_chars then s
    else truncate ~max_chars:blocker_detail_structured_max_chars s
  else truncate ~max_chars:blocker_detail_narrative_max_chars s

let string_list_of_assoc key json =
  match Json_field.list json key |> Json_field.to_option with
  | None -> []
  | Some values ->
    values
    |> List.filter_map (function
         | `String value -> Some value
         | _ -> None)
;;

let provider_rejection_of_json json =
  let provider_label =
    Json_field.string json "provider_label" |> Json_field.to_option
    |> Option.value ~default:""
  in
  match Json_field.string json "reason" |> Json_field.to_option with
  | Some reason -> Some { provider_label; reason }
  | None -> None
;;

let provider_rejections_of_assoc key json =
  match Json_field.list json key |> Json_field.to_option with
  | None -> []
  | Some values -> List.filter_map provider_rejection_of_json values
;;

let provider_rejection_reasons_of_assoc key json =
  string_list_of_assoc key json
  |> List.map (fun reason -> { provider_label = ""; reason })

let provider_rejection_reasons rejections =
  rejections
  |> List.map (fun r -> String.trim r.reason)
  |> List.filter (fun reason -> reason <> "")
  |> Json_util.dedupe_keep_order

let string_opt_of_assoc key json =
  Json_field.string json key |> Json_field.to_option
;;

let network_error_kind_to_string = function
  | Llm_provider.Http_client.Connection_refused -> "connection_refused"
  | Llm_provider.Http_client.Dns_failure -> "dns_failure"
  | Llm_provider.Http_client.Tls_error -> "tls_error"
  | Llm_provider.Http_client.Timeout -> "timeout"
  | Llm_provider.Http_client.Local_resource_exhaustion -> "local_resource_exhaustion"
  | Llm_provider.Http_client.End_of_file -> "end_of_file"
  | Llm_provider.Http_client.Unknown -> "unknown"
;;

let network_error_kind_of_string = function
  | "connection_refused" -> Some Llm_provider.Http_client.Connection_refused
  | "dns_failure" -> Some Llm_provider.Http_client.Dns_failure
  | "tls_error" -> Some Llm_provider.Http_client.Tls_error
  | "timeout" -> Some Llm_provider.Http_client.Timeout
  | "local_resource_exhaustion" ->
    Some Llm_provider.Http_client.Local_resource_exhaustion
  | "end_of_file" -> Some Llm_provider.Http_client.End_of_file
  | "unknown" -> Some Llm_provider.Http_client.Unknown
  | _ -> None
;;

let transport_error_kind_json_fields = function
  | None -> []
  | Some kind -> [ "transport_error_kind", `String (network_error_kind_to_string kind) ]
;;

let masc_internal_error_to_json = function
  | Runtime_exhausted { runtime_id; reason } ->
    let runtime_id = runtime_id_to_string runtime_id in
    `Assoc
      [
        ("kind", `String "runtime_exhausted");
        ("runtime_id", `String runtime_id);
        ("reason", runtime_exhaustion_reason_to_json reason);
      ]
  | Capacity_backpressure { runtime_id; source; detail; retry_after; cooldown_cause } ->
    let runtime_id = runtime_id_to_string runtime_id in
    let retry_after_fields =
      match retry_after with
      | Explicit s -> [ "retry_after_sec", `Float s ]
      | No_retry_hint -> [ ("retry_after_sec", `Null) ]
    in
    let cooldown_cause_fields =
      match cooldown_cause with
      | Some cause ->
        [ ("cooldown_cause", `String (provider_cooldown_cause_to_string cause)) ]
      | None -> []
    in
    `Assoc
      ([
         ("kind", `String capacity_backpressure_kind);
         ("runtime_id", `String runtime_id);
         ("source", `String (capacity_backpressure_source_to_string source));
         ("detail", `String detail);
       ]
      @ retry_after_fields
      @ cooldown_cause_fields)
  | Resumable_cli_session { runtime_id; detail; exit_code } ->
    let runtime_id = runtime_id_to_string runtime_id in
    `Assoc
      [
        ("kind", `String "resumable_cli_session");
        ("runtime_id", `String runtime_id);
        ("detail", `String detail);
        ("exit_code", Json_util.int_opt_to_json exit_code);
      ]
  | Accept_rejected
      {
        scope;
        model;
        reason_kind;
        response_shape;
        stop_reason;
        reason;
      } ->
    `Assoc
      [
        ("kind", `String "accept_rejected");
        ("scope", `String scope);
        ("model", Json_util.string_opt_to_json model);
        ( "reason_kind",
          Json_util.string_opt_to_json
            (Option.map accept_rejection_kind_to_string reason_kind) );
        ( "response_shape",
          Json_util.string_opt_to_json
            (Option.map accept_response_shape_to_string response_shape) );
        ( "stop_reason",
          Json_util.string_opt_to_json
            (Option.map Agent_sdk.Types.stop_reason_to_string stop_reason) );
        ("reason", `String reason);
      ]
  | Turn_timeout { elapsed_sec } ->
    `Assoc
      [
        ("kind", `String "turn_timeout");
        ("elapsed_sec", `Float elapsed_sec);
      ]
  | Provider_timeout
      {
        budget_sec;
        keeper_turn_timeout_sec;
        estimated_input_tokens;
        source;
        remaining_turn_budget_sec;
        min_required_sec;
        phase;
      } ->
    `Assoc
      [
        ("kind", `String "provider_timeout");
        ("budget_sec", `Float budget_sec);
        ("keeper_turn_timeout_sec", `Float keeper_turn_timeout_sec);
        ("estimated_input_tokens", `Int estimated_input_tokens);
        ("source", `String source);
        ( "remaining_turn_budget_sec",
          Json_util.float_opt_to_json remaining_turn_budget_sec );
        ("min_required_sec", `Float min_required_sec);
        ("phase", `String phase);
      ]
  | Internal_unhandled_exception { site; exn_repr; transport_error_kind } ->
    `Assoc
      ([ ("kind", `String "internal_unhandled_exception")
       ; ("site", `String site)
       ; ("exn_repr", `String exn_repr)
       ]
       @ transport_error_kind_json_fields transport_error_kind)
  | Internal_bridge_exception { caller; exn_repr } ->
    `Assoc
      [
        ("kind", `String "internal_bridge_exception");
        ("caller", `String caller);
        ("exn_repr", `String exn_repr);
      ]
  | Internal_contract_rejected { reason } ->
    `Assoc
      [
        ("kind", `String "internal_contract_rejected");
        ("reason", `String reason);
      ]
  | Receipt_persistence_failed { detail } ->
    `Assoc
      [
        ("kind", `String "receipt_persistence_failed");
        ("detail", `String detail);
      ]

let summarize_list ?(empty = "none") values =
  match values with
  | [] -> empty
  | _ -> String.concat ", " values

let accept_rejection_summary_max_bytes = 180

let short_accept_rejection_reason reason =
  (* Keep accept-rejection summaries below the 200-byte narrative blocker cap
     so the full summary fits when it is embedded in blocker detail. *)
  String_util.utf8_safe
    ~max_bytes:accept_rejection_summary_max_bytes
    ~suffix:"..."
    (String.trim reason)
  |> String_util.to_string

let nonempty_or_unknown value =
  let value = String.trim value in
  if String.equal value "" then "unknown" else value

let accept_rejection_kind_display = function
  | Some kind -> accept_rejection_kind_to_string kind
  | None -> "unknown"

let accept_response_shape_display = function
  | Some shape -> accept_response_shape_to_string shape
  | None -> "unknown"

let accept_rejection_is_empty_no_progress ~reason_kind ~response_shape =
  reason_kind = Some Accept_no_usable_progress
  && response_shape = Some Accept_response_empty

let accept_rejection_is_thinking_only_no_progress ~reason_kind ~response_shape =
  reason_kind = Some Accept_no_usable_progress
  && response_shape = Some Accept_response_thinking_only

let summary_of_masc_internal_error = function
  | Capacity_backpressure { runtime_id; source; detail; retry_after; cooldown_cause } ->
      let retry_after_suffix =
        match retry_after with
        | Explicit value -> Printf.sprintf "; retry_after=%.1fs" value
        | No_retry_hint -> ""
      in
      let cooldown_cause_suffix =
        match cooldown_cause with
        | Some cause ->
          Printf.sprintf "; cooldown_cause=%s"
            (provider_cooldown_cause_to_string cause)
        | None -> ""
      in
      Some
        (Printf.sprintf
           "Capacity backpressure blocked runtime %s; source=%s; detail=%s%s%s"
           (runtime_id_to_string runtime_id)
           (capacity_backpressure_source_to_string source)
           detail
           retry_after_suffix
           cooldown_cause_suffix)
  | Provider_timeout
      {
        budget_sec;
        keeper_turn_timeout_sec;
        estimated_input_tokens;
        source;
        remaining_turn_budget_sec;
        min_required_sec;
        phase;
      } ->
      let remaining =
        match remaining_turn_budget_sec with
        | Some value -> Printf.sprintf "%.1fs" value
        | None -> "unknown"
      in
      Some
        (Printf.sprintf
           "Provider timeout exhausted; phase=%s; source=%s; budget=%.1fs; remaining=%s; min_required=%.1fs; estimated_input_tokens=%d; keeper_turn_timeout=%.1fs"
           phase source budget_sec remaining min_required_sec
           estimated_input_tokens keeper_turn_timeout_sec)
  | Accept_rejected
      {
        scope;
        reason_kind;
        response_shape;
        _;
      }
    when accept_rejection_is_empty_no_progress
           ~reason_kind
           ~response_shape ->
    Some
      (Printf.sprintf
         "Provider returned an empty assistant turn for runtime %s; no text or tool progress was produced."
         (nonempty_or_unknown scope))
  | Accept_rejected
      {
        scope;
        reason_kind;
        response_shape;
        _;
      }
    when accept_rejection_is_thinking_only_no_progress
           ~reason_kind
           ~response_shape ->
    Some
      (Printf.sprintf
         "Provider returned a thinking-only assistant turn for runtime %s; no text or tool progress was produced."
         (nonempty_or_unknown scope))
  | Accept_rejected
      {
        scope;
        reason_kind = Some Accept_predicate_rejected;
        response_shape;
        reason;
        _;
      } ->
    let shape = accept_response_shape_display response_shape in
    Some
      (Printf.sprintf
         "Provider response for runtime %s was rejected by the accept predicate; response_shape=%s; reason=%s"
         (nonempty_or_unknown scope)
         shape
         (short_accept_rejection_reason reason))
  | Accept_rejected { scope; reason_kind; response_shape; reason; _ } ->
    let reason_kind = accept_rejection_kind_display reason_kind in
    let response_shape = accept_response_shape_display response_shape in
    Some
      (Printf.sprintf
         "Provider response for runtime %s was rejected by the keeper accept contract; reason_kind=%s; response_shape=%s; reason=%s"
         (nonempty_or_unknown scope)
         reason_kind
         response_shape
         (short_accept_rejection_reason reason))
  | Runtime_exhausted { runtime_id; reason } ->
    Some
      (Printf.sprintf
         "Runtime %s exhausted all candidates; reason=%s"
         (nonempty_or_unknown runtime_id)
         (runtime_exhaustion_reason_to_label reason))
  | Resumable_cli_session _
  | Turn_timeout _
  | Internal_unhandled_exception _
  | Internal_bridge_exception _
  | Internal_contract_rejected _
  | Receipt_persistence_failed _ -> None

let kind_of_masc_internal_error = function
  | Runtime_exhausted _ -> "runtime_exhausted"
  | Capacity_backpressure _ -> capacity_backpressure_kind
  | Resumable_cli_session _ -> "resumable_cli_session"
  | Accept_rejected _ -> "accept_rejected"
  | Turn_timeout _ -> "turn_timeout"
  | Provider_timeout _ -> "provider_timeout"
  | Internal_unhandled_exception _ -> "internal_unhandled_exception"
  | Internal_bridge_exception _ -> "internal_bridge_exception"
  | Internal_contract_rejected _ -> "internal_contract_rejected"
  | Receipt_persistence_failed _ -> "receipt_persistence_failed"

let runtime_id_of_masc_internal_error = function
  | Runtime_exhausted { runtime_id; _ }
  | Capacity_backpressure { runtime_id; _ }
  | Resumable_cli_session { runtime_id; _ } ->
      let runtime_id = runtime_id_to_string runtime_id in
      if String.equal (String.trim runtime_id) "" then "unknown"
      else runtime_id
  | Accept_rejected { scope; _ } ->
      nonempty_or_unknown scope
  | Turn_timeout _
  | Provider_timeout _
  | Internal_unhandled_exception _
  | Internal_bridge_exception _
  | Internal_contract_rejected _
  | Receipt_persistence_failed _ -> "unknown"

let accept_no_progress_retry_kind = function
  | Accept_rejected
      {
        reason_kind;
        response_shape;
        _;
      }
    when accept_rejection_is_empty_no_progress
           ~reason_kind
           ~response_shape ->
    Some `Empty_no_progress
  | Accept_rejected
      {
        reason_kind;
        response_shape;
        _;
      }
    when accept_rejection_is_thinking_only_no_progress
           ~reason_kind
           ~response_shape ->
    Some `Thinking_only_no_progress
  | Accept_rejected _
  | Runtime_exhausted _
  | Capacity_backpressure _
  | Resumable_cli_session _
  | Turn_timeout _
  | Provider_timeout _
  | Internal_unhandled_exception _
  | Internal_bridge_exception _
  | Internal_contract_rejected _
  | Receipt_persistence_failed _ ->
    None

let accept_rejection_has_no_progress_retry_hint err =
  match accept_no_progress_retry_kind err with
  | Some (`Empty_no_progress | `Thinking_only_no_progress) ->
    true
  | None -> false

let sdk_error_of_masc_internal_error err =
  Agent_sdk.Error.Internal
    (masc_internal_error_prefix ^ Yojson.Safe.to_string (masc_internal_error_to_json err))

(* ------------------------------------------------------------------ *)
(* Reverse direction: SDK envelope -> typed variant.                  *)
(* ------------------------------------------------------------------ *)

let parse_masc_internal_error_json (json : Yojson.Safe.t) :
    masc_internal_error option =
  let exact_fields expected fields =
    let sort = List.sort String.compare in
    sort expected = sort (List.map fst fields)
  in
  let int_opt_of_assoc key = function
    | `Assoc fields -> (
        match List.assoc_opt key fields with
        | Some (`Int value) -> Some value
        | Some (`Intlit value) -> int_of_string_opt value
        | _ -> None)
    | _ -> None
  in
  let float_opt_of_assoc key = function
    | `Assoc fields -> (
        match List.assoc_opt key fields with
        | Some (`Float value) -> Some value
        | Some (`Int value) -> Some (float_of_int value)
        | Some (`Intlit value) ->
            Option.map float_of_int (int_of_string_opt value)
        | _ -> None)
    | _ -> None
  in
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "kind" fields with
      | Some (`String "runtime_exhausted") -> (
          match string_opt_of_assoc "runtime_id" json with
          | Some runtime_id ->
            let reason_opt =
              match List.assoc_opt "reason"
                      (match json with `Assoc fields -> fields | _ -> []) with
              | Some json_val ->
                  runtime_exhaustion_reason_of_json json_val
              | None -> None
            in
            (match reason_opt with
             | Some reason ->
               Some (Runtime_exhausted { runtime_id; reason })
             | None -> None)
          | None -> None)
      | Some (`String kind) when String.equal kind capacity_backpressure_kind -> (
          match
            string_opt_of_assoc "runtime_id" json,
            string_opt_of_assoc "source" json,
            string_opt_of_assoc "detail" json
          with
          | Some runtime_id, Some source, Some detail ->
            (match capacity_backpressure_source_of_string source with
             | Some source
               when exact_fields
                      [ "kind"
                      ; "runtime_id"
                      ; "source"
                      ; "detail"
                      ; "retry_after_sec"
                      ]
                      fields
                    || exact_fields
                         [ "kind"
                         ; "runtime_id"
                         ; "source"
                         ; "detail"
                         ; "retry_after_sec"
                         ; "cooldown_cause"
                         ]
                         fields ->
               let retry_after =
                 match float_opt_of_assoc "retry_after_sec" json with
                 | None -> No_retry_hint
                 | Some s -> Explicit s
               in
               let cooldown_cause =
                 match string_opt_of_assoc "cooldown_cause" json with
                 | Some raw -> provider_cooldown_cause_of_string raw
                 | None -> None
               in
               Some
                 (Capacity_backpressure
                    { runtime_id; source; detail; retry_after; cooldown_cause })
             | Some _ | None -> None)
          | _ -> None)
      | Some (`String "resumable_cli_session") -> (
          match string_opt_of_assoc "runtime_id" json, string_opt_of_assoc "detail" json with
          | Some runtime_id, Some detail ->
            Some
              (Resumable_cli_session
                 {
                   runtime_id;
                   detail;
                   exit_code = int_opt_of_assoc "exit_code" json;
                 })
          | _ -> None)
      | Some (`String "accept_rejected") -> (
          match string_opt_of_assoc "scope" json, string_opt_of_assoc "reason" json with
          | Some scope, Some reason ->
            Some
              (Accept_rejected
                 {
                   scope;
                   model = string_opt_of_assoc "model" json;
                   reason_kind =
                     Option.bind
                       (string_opt_of_assoc "reason_kind" json)
                       accept_rejection_kind_of_string;
                   response_shape =
                     Option.bind
                       (string_opt_of_assoc "response_shape" json)
                       accept_response_shape_of_string;
                   stop_reason =
                     Option.map
                       Agent_sdk.Types.stop_reason_of_string
                       (string_opt_of_assoc "stop_reason" json);
                   reason;
                 })
          | _ -> None)
      | Some (`String "turn_timeout") -> (
          match json with
          | `Assoc fields -> (
              match List.assoc_opt "elapsed_sec" fields with
              | Some (`Float v) ->
                Some (Turn_timeout { elapsed_sec = v })
              | _ -> None)
          | _ -> None)
      | Some (`String "provider_timeout") -> (
          match json with
          | `Assoc fields -> (
              match
                List.assoc_opt "budget_sec" fields,
                List.assoc_opt "keeper_turn_timeout_sec" fields,
                List.assoc_opt "estimated_input_tokens" fields,
                List.assoc_opt "source" fields
              with
              | Some (`Float budget_sec),
                Some (`Float keeper_turn_timeout_sec),
                Some (`Int estimated_input_tokens),
                Some (`String source) ->
                  Some
                    (Provider_timeout
                       {
                         budget_sec;
                         keeper_turn_timeout_sec;
                         estimated_input_tokens;
                         source;
                         remaining_turn_budget_sec =
                           float_opt_of_assoc
                             "remaining_turn_budget_sec" json;
                         min_required_sec =
                           Option.value ~default:0.0
                             (float_opt_of_assoc "min_required_sec" json);
                         phase =
                           Option.value ~default:"unknown"
                             (string_opt_of_assoc "phase" json);
                       })
              | _ -> None)
          | _ -> None)
      | Some (`String "internal_unhandled_exception") -> (
          match string_opt_of_assoc "site" json, string_opt_of_assoc "exn_repr" json with
          | Some site, Some exn_repr ->
            (match string_opt_of_assoc "transport_error_kind" json with
             | None ->
               Some
                 (Internal_unhandled_exception
                    { site; exn_repr; transport_error_kind = None })
             | Some raw_kind ->
               (match network_error_kind_of_string raw_kind with
                | Some transport_error_kind ->
                  Some
                    (Internal_unhandled_exception
                       { site; exn_repr; transport_error_kind = Some transport_error_kind })
                | None -> None))
          | _ -> None)
      | Some (`String "internal_bridge_exception") -> (
          match string_opt_of_assoc "caller" json,
                string_opt_of_assoc "exn_repr" json
          with
          | Some caller, Some exn_repr ->
            Some (Internal_bridge_exception { caller; exn_repr })
          | _ -> None)
      | Some (`String "internal_contract_rejected") -> (
          match string_opt_of_assoc "reason" json with
          | Some reason -> Some (Internal_contract_rejected { reason })
          | _ -> None)
      | Some (`String "receipt_persistence_failed") -> (
          match string_opt_of_assoc "detail" json with
          | Some detail -> Some (Receipt_persistence_failed { detail })
          | _ -> None)
      | _ -> None)
  | _ -> None

let classify_masc_internal_error_of_string (raw : string) :
    masc_internal_error option =
  let prefix = masc_internal_error_prefix in
  let prefix_len = String.length prefix in
  let raw_len = String.length raw in
  let rec find_prefix start =
    if start + prefix_len > raw_len then None
    else if String.sub raw start prefix_len = prefix then Some start
    else find_prefix (start + 1)
  in
  match find_prefix 0 with
  | None -> None
  | Some prefix_start ->
    let payload_start = prefix_start + prefix_len in
    let payload = String.sub raw payload_start (raw_len - payload_start) in
    (try parse_masc_internal_error_json (Yojson.Safe.from_string payload)
     with Yojson.Json_error _ -> None)

let classify_masc_internal_error (err : Agent_sdk.Error.sdk_error) :
    masc_internal_error option =
  match err with
  | Agent_sdk.Error.Internal msg -> classify_masc_internal_error_of_string msg
  | _ -> None
