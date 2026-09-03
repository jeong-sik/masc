(** Keeper_internal_error — the [masc_internal_error] ADT, its JSON codec, and the reverse-direction
    agent-core envelope parser.

    This is the structured *typed envelope* carried across the
    [Agent_core.Error.Internal _] boundary for keeper turn failures.  It is the
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
let incomplete_tool_transcript_kind = "incomplete_tool_transcript"
let provider_attempt_effect_fenced_kind = "provider_attempt_effect_fenced"
let tool_correction_lost_kind = "tool_correction_lost"
let accept_rejected_kind = "accept_rejected"
let terminal_effect_failed_kind = "terminal_effect_failed"

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

type runtime_exhaustion_reason =
  | Connection_refused
  | Dns_failure
  | No_providers_available
  | All_providers_failed
  | Candidates_filtered_after_cycles
  | Session_conflict
  | Capacity_exhausted
  | Other_detail of string

let runtime_exhaustion_reason_retryable = function
  | Candidates_filtered_after_cycles | Capacity_exhausted -> true
  | Connection_refused | Dns_failure | No_providers_available | All_providers_failed ->
    true
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
  | Session_conflict -> "session_conflict"
  | Capacity_exhausted -> "capacity_exhausted"
  | Other_detail detail ->
    Printf.sprintf "other(%s)" (runtime_exhaustion_label_payload detail)

let runtime_exhaustion_reason_to_json = function
  | Connection_refused -> `String "connection_refused"
  | Dns_failure -> `String "dns_failure"
  | No_providers_available -> `String "no_providers_available"
  | All_providers_failed -> `String "all_providers_failed"
  | Candidates_filtered_after_cycles -> `String "candidates_filtered_after_cycles"
  | Session_conflict -> `String "session_conflict"
  | Capacity_exhausted -> `String "capacity_exhausted"
  | Other_detail msg -> `Assoc [ "tag", `String "other_detail"; "message", `String msg ]

let runtime_exhaustion_reason_of_json = function
  | `String "connection_refused" -> Some Connection_refused
  | `String "dns_failure" -> Some Dns_failure
  | `String "no_providers_available" -> Some No_providers_available
  | `String "all_providers_failed" -> Some All_providers_failed
  | `String "candidates_filtered_after_cycles" -> Some Candidates_filtered_after_cycles
  | `String "session_conflict" -> Some Session_conflict
  | `String "capacity_exhausted" -> Some Capacity_exhausted
  | `Assoc fields ->
    (match List.assoc_opt "tag" fields with
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

let accept_response_shape_of_agent_core = function
  | Agent_core.Response_shape.Empty -> Accept_response_empty
  | Agent_core.Response_shape.Thinking_only -> Accept_response_thinking_only
  | Agent_core.Response_shape.Blank_text_only -> Accept_response_blank_text_only
  | Agent_core.Response_shape.Tool_result_only -> Accept_response_tool_result_only
  | Agent_core.Response_shape.Media_only -> Accept_response_media_only
  | Agent_core.Response_shape.Mixed_without_deliverable_content ->
    Accept_response_mixed_without_deliverable_content
  | Agent_core.Response_shape.Has_deliverable_content ->
    Accept_response_has_deliverable_content
;;

type transcript_quarantine_reason =
  | Structurally_invalid
  | Unresolved_tool_results

let transcript_quarantine_reason_to_string = function
  | Structurally_invalid -> "structurally_invalid"
  | Unresolved_tool_results -> "unresolved_tool_results"
;;

let transcript_quarantine_reason_of_string = function
  | "structurally_invalid" -> Some Structurally_invalid
  | "unresolved_tool_results" -> Some Unresolved_tool_results
  | _ -> None
;;

type gate_replay_repair_stage =
  | Replay_resolution_lookup
  | Replay_request_decode
  | Replay_evidence_storage
  | Replay_evidence_retrieval
  | Replay_journal
  | Replay_stale_grant_retirement
  | Replay_invalid_resolution_state

let gate_replay_repair_stage_to_string = function
  | Replay_resolution_lookup -> "resolution_lookup"
  | Replay_request_decode -> "request_decode"
  | Replay_evidence_storage -> "evidence_storage"
  | Replay_evidence_retrieval -> "evidence_retrieval"
  | Replay_journal -> "replay_journal"
  | Replay_stale_grant_retirement -> "stale_grant_retirement"
  | Replay_invalid_resolution_state -> "invalid_resolution_state"
;;

let gate_replay_repair_stage_of_string = function
  | "resolution_lookup" -> Some Replay_resolution_lookup
  | "request_decode" -> Some Replay_request_decode
  | "evidence_storage" -> Some Replay_evidence_storage
  | "evidence_retrieval" -> Some Replay_evidence_retrieval
  | "replay_journal" -> Some Replay_journal
  | "stale_grant_retirement" -> Some Replay_stale_grant_retirement
  | "invalid_resolution_state" -> Some Replay_invalid_resolution_state
  | _ -> None
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
         [MaxTokens] marks an exhausted output budget and must be
         distinguished from a clean [EndTurn] no-progress terminal — AGENT_CORE
         gates its own [ended_without_deliverable_content] on [EndTurn] for
         exactly this reason. Consumed by [accept_no_progress_retry_kind]: it
         offers the thinking-off continuation to every [MaxTokens] no-progress
         rejection, while the retry kind follows the shape first (empty and
         thinking-only keep their rotation kinds) and is [`Truncated_no_progress]
         only for the remaining [MaxTokens] shapes. [summary_of_masc_internal_error]
         reports the budget boundary for every [MaxTokens] rejection; that is a
         statement about what happened, not about the retry kind. *)
      stop_reason : Agent_core.Types.stop_reason option;
      reason : string;
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
  | Incomplete_tool_transcript of {
      reason : transcript_quarantine_reason;
      detail : string;
      tool_use_ids : string list;
    }
  | Terminal_effect_failed of {
      failure_class : Tool_result.tool_failure_class;
      effect_disposition : Tool_result.failure_effect_disposition;
      diagnostic : string;
    }
  | Provider_attempt_effect_fenced of {
      runtime_id : string;
      effect_disposition : Keeper_provider_attempt_effect_core.t;
      diagnostic : string;
    }
  | Tool_correction_lost of {
      runtime_id : string;
      effect_disposition : Keeper_provider_attempt_effect_core.t;
      reject_count : int;
      diagnostic : string;
    }
  | Receipt_persistence_failed of {
      detail : string;
    }
  | Gate_replay_repair_required of {
      approval_id : string;
      operation : string;
      stage : gate_replay_repair_stage;
      detail : string;
    }

let masc_internal_error_prefix = "[masc_agent_core_error] "
let runtime_runner_execute_site = "runtime_runner.execute"

(* #9933: a keeper [blocker_info] detail string may carry a structured
   [masc_agent_core_error] JSON payload — [masc_internal_error_prefix] above,
   possibly wrapped by Agent_core.Error.to_string's "Internal error: ".
   Truncating it at the narrative budget slices the JSON mid-key, so
   downstream consumers (dashboard, retry classifier, log search) lose the
   diagnostic fields (budget_sec, source, …). [cap_blocker_detail] keeps a
   payload that begins with the prefix up to
   [blocker_detail_structured_max_chars] and truncates plain narrative text
   to [blocker_detail_narrative_max_chars]. Idempotent. Applied where the
   runtime builds a blocker detail string
   (keeper_unified_metrics_failure). *)
let blocker_detail_narrative_max_chars = 200

(* ~2000 chars fits a Yojson-encoded masc_internal_error record of any
   current variant plus the wrapping prefix, with headroom. Past this the
   payload is pathological and we cap rather than store unbounded blobs. *)
let blocker_detail_structured_max_chars = 2000

let masc_agent_core_error_bare_prefix = String.trim masc_internal_error_prefix
let masc_agent_core_error_wrapped_prefix = "Internal error: " ^ masc_agent_core_error_bare_prefix

let has_masc_agent_core_error_prefix (s : string) : bool =
  String.starts_with ~prefix:masc_agent_core_error_bare_prefix s
  || String.starts_with ~prefix:masc_agent_core_error_wrapped_prefix s

let cap_blocker_detail (s : string) : string =
  (* +3 bytes of headroom for the "…" ellipsis suffix. *)
  let truncate ~max_chars s =
    String_util.utf8_safe ~max_bytes:(max_chars + 3) ~suffix:"…" s
    |> String_util.to_string
  in
  if has_masc_agent_core_error_prefix (String.trim s) then
    if String.length s <= blocker_detail_structured_max_chars then s
    else truncate ~max_chars:blocker_detail_structured_max_chars s
  else truncate ~max_chars:blocker_detail_narrative_max_chars s

let string_opt_of_assoc key json =
  Json_field.string json key |> Json_field.to_option
;;

let string_list_of_assoc key json =
  match Json_field.list json key |> Json_field.to_option with
  | None -> []
  | Some values ->
    values
    |> List.filter_map (function
         | `String value -> Some value
         | _ -> None)
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
  | Capacity_backpressure { runtime_id; source; detail; retry_after } ->
    let runtime_id = runtime_id_to_string runtime_id in
    let retry_after_fields =
      match retry_after with
      | Explicit s -> [ "retry_after_sec", `Float s ]
      | No_retry_hint -> [ ("retry_after_sec", `Null) ]
    in
    `Assoc
      ([
         ("kind", `String capacity_backpressure_kind);
         ("runtime_id", `String runtime_id);
         ("source", `String (capacity_backpressure_source_to_string source));
         ("detail", `String detail);
       ]
      @ retry_after_fields)
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
            (Option.map Agent_core.Types.stop_reason_to_string stop_reason) );
        ("reason", `String reason);
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
  | Incomplete_tool_transcript { reason; detail; tool_use_ids } ->
    `Assoc
      [
        ("kind", `String incomplete_tool_transcript_kind);
        ("reason", `String (transcript_quarantine_reason_to_string reason));
        ("detail", `String detail);
        ("tool_use_ids", `List (List.map (fun id -> `String id) tool_use_ids));
      ]
  | Terminal_effect_failed { failure_class; effect_disposition; diagnostic } ->
    `Assoc
      [
        ("kind", `String "terminal_effect_failed");
        ("failure_class", `String (Tool_result.tool_failure_class_to_string failure_class));
        ( "effect_disposition"
        , `String
            (Tool_result.failure_effect_disposition_to_string effect_disposition)
        );
        ("diagnostic", `String diagnostic);
      ]
  | Provider_attempt_effect_fenced
      { runtime_id; effect_disposition; diagnostic } ->
    `Assoc
      [ "kind", `String provider_attempt_effect_fenced_kind
      ; "runtime_id", `String runtime_id
      ; ( "effect_disposition"
        , `String (Keeper_provider_attempt_effect_core.to_string effect_disposition) )
      ; "diagnostic", `String diagnostic
      ]
  | Tool_correction_lost
      { runtime_id; effect_disposition; reject_count; diagnostic } ->
    `Assoc
      [ "kind", `String tool_correction_lost_kind
      ; "runtime_id", `String runtime_id
      ; ( "effect_disposition"
        , `String (Keeper_provider_attempt_effect_core.to_string effect_disposition) )
      ; "reject_count", `Int reject_count
      ; "diagnostic", `String diagnostic
      ]
  | Receipt_persistence_failed { detail } ->
    `Assoc
      [
        ("kind", `String "receipt_persistence_failed");
        ("detail", `String detail);
      ]
  | Gate_replay_repair_required { approval_id; operation; stage; detail } ->
    `Assoc
      [ "kind", `String "gate_replay_repair_required"
      ; "approval_id", `String approval_id
      ; "operation", `String operation
      ; "stage", `String (gate_replay_repair_stage_to_string stage)
      ; "detail", `String detail
      ]

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
  | Capacity_backpressure { runtime_id; source; detail; retry_after } ->
      let retry_after_suffix =
        match retry_after with
        | Explicit value -> Printf.sprintf "; retry_after=%.1fs" value
        | No_retry_hint -> ""
      in
      Some
        (Printf.sprintf
           "Capacity backpressure blocked runtime %s; source=%s; detail=%s%s"
           (runtime_id_to_string runtime_id)
           (capacity_backpressure_source_to_string source)
           detail
           retry_after_suffix)
  | Accept_rejected
      { scope
      ; reason_kind = Some Accept_no_usable_progress
      ; stop_reason = Some Agent_core.Types.MaxTokens
      ; _
      } ->
    Some
      (Printf.sprintf
         "Provider output for runtime %s reached its maximum token boundary before completion."
         (nonempty_or_unknown scope))
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
  | Internal_unhandled_exception _
  | Internal_bridge_exception _
  | Internal_contract_rejected _
  | Incomplete_tool_transcript _
  | Terminal_effect_failed _
  | Provider_attempt_effect_fenced _
  | Tool_correction_lost _
  | Receipt_persistence_failed _
  | Gate_replay_repair_required _ -> None

type wire_kind =
  | Wire_runtime_exhausted
  | Wire_capacity_backpressure
  | Wire_resumable_cli_session
  | Wire_accept_rejected
  | Wire_internal_unhandled_exception
  | Wire_internal_bridge_exception
  | Wire_internal_contract_rejected
  | Wire_incomplete_tool_transcript
  | Wire_terminal_effect_failed
  | Wire_provider_attempt_effect_fenced
  | Wire_tool_correction_lost
  | Wire_receipt_persistence_failed
  | Wire_gate_replay_repair_required

let wire_kind_of_masc_internal_error = function
  | Runtime_exhausted _ -> Wire_runtime_exhausted
  | Capacity_backpressure _ -> Wire_capacity_backpressure
  | Resumable_cli_session _ -> Wire_resumable_cli_session
  | Accept_rejected _ -> Wire_accept_rejected
  | Internal_unhandled_exception _ -> Wire_internal_unhandled_exception
  | Internal_bridge_exception _ -> Wire_internal_bridge_exception
  | Internal_contract_rejected _ -> Wire_internal_contract_rejected
  | Incomplete_tool_transcript _ -> Wire_incomplete_tool_transcript
  | Terminal_effect_failed _ -> Wire_terminal_effect_failed
  | Provider_attempt_effect_fenced _ -> Wire_provider_attempt_effect_fenced
  | Tool_correction_lost _ -> Wire_tool_correction_lost
  | Receipt_persistence_failed _ -> Wire_receipt_persistence_failed
  | Gate_replay_repair_required _ -> Wire_gate_replay_repair_required

let wire_kind_to_string = function
  | Wire_runtime_exhausted -> "runtime_exhausted"
  | Wire_capacity_backpressure -> capacity_backpressure_kind
  | Wire_resumable_cli_session -> "resumable_cli_session"
  | Wire_accept_rejected -> accept_rejected_kind
  | Wire_internal_unhandled_exception -> "internal_unhandled_exception"
  | Wire_internal_bridge_exception -> "internal_bridge_exception"
  | Wire_internal_contract_rejected -> "internal_contract_rejected"
  | Wire_incomplete_tool_transcript -> incomplete_tool_transcript_kind
  | Wire_terminal_effect_failed -> terminal_effect_failed_kind
  | Wire_provider_attempt_effect_fenced -> provider_attempt_effect_fenced_kind
  | Wire_tool_correction_lost -> tool_correction_lost_kind
  | Wire_receipt_persistence_failed -> "receipt_persistence_failed"
  | Wire_gate_replay_repair_required -> "gate_replay_repair_required"

(* Decoding scans this list through [wire_kind_to_string] rather than
   repeating the strings, so encoder and decoder cannot spell a kind
   differently. *)
let all_wire_kinds =
  [ Wire_runtime_exhausted
  ; Wire_capacity_backpressure
  ; Wire_resumable_cli_session
  ; Wire_accept_rejected
  ; Wire_internal_unhandled_exception
  ; Wire_internal_bridge_exception
  ; Wire_internal_contract_rejected
  ; Wire_incomplete_tool_transcript
  ; Wire_terminal_effect_failed
  ; Wire_provider_attempt_effect_fenced
  ; Wire_tool_correction_lost
  ; Wire_receipt_persistence_failed
  ; Wire_gate_replay_repair_required
  ]

(* A wire reason is either the bare kind or [kind:params] -- a producer
   appends the call's parameters after a colon. Read the kind and leave the
   parameters to the payload, so a reason that carries them decodes to its
   typed kind instead of falling through as [Unknown]. *)
let wire_kind_of_string wire =
  let kind =
    match String.index_opt wire ':' with
    | None -> wire
    | Some colon -> String.sub wire 0 colon
  in
  List.find_opt
    (fun candidate -> String.equal (wire_kind_to_string candidate) kind)
    all_wire_kinds
;;

let kind_of_masc_internal_error error =
  wire_kind_to_string (wire_kind_of_masc_internal_error error)
;;

let runtime_id_of_masc_internal_error = function
  | Runtime_exhausted { runtime_id; _ }
  | Capacity_backpressure { runtime_id; _ }
  | Resumable_cli_session { runtime_id; _ }
  | Provider_attempt_effect_fenced { runtime_id; _ }
  | Tool_correction_lost { runtime_id; _ } ->
      let runtime_id = runtime_id_to_string runtime_id in
      if String.equal (String.trim runtime_id) "" then "unknown"
      else runtime_id
  | Accept_rejected { scope; _ } ->
      nonempty_or_unknown scope
  | Internal_unhandled_exception _
  | Internal_bridge_exception _
  | Internal_contract_rejected _
  | Incomplete_tool_transcript _
  | Terminal_effect_failed _
  | Receipt_persistence_failed _
  | Gate_replay_repair_required _ -> "unknown"

(* The two shapes that already have rotation kinds decide before the stop
   reason: an empty or thinking-only response keeps [`Empty_no_progress] /
   [`Thinking_only_no_progress] whether the provider stopped at [EndTurn] or at
   [MaxTokens]. The truncation-continuation attempt is unaffected: it runs
   first on every [MaxTokens] no-progress rejection, because
   [Keeper_turn_driver_try_provider.max_tokens_truncation_error] reads the
   record, not this kind. [`Truncated_no_progress] is every other [MaxTokens]
   shape; it has no rotation hint, so a failed continuation on it ends the
   lane.

   Before this order, every [MaxTokens] rejection was [`Truncated_no_progress].
   On a lane whose dialect drops [enable_thinking = false] from the wire
   (Chat_completions with the reasoning_effort dialect), the continuation is
   the same request again: 2026-09-02 17:39-18:06 KST analyst ran nine
   thinking-only max_tokens turns (first generation 68-116 s, continuation
   52-88 s more, same result), each classified [`Truncated_no_progress], each
   ending with [deferred_next_runtime=none] while glm-coding.glm-5.3 stood
   second in its lane. With the shape kinds restored the failed continuation
   defers the next cycle to that sibling. The identical second generation
   itself is the dialect's silent drop, tracked separately. *)
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
  | Accept_rejected
      { reason_kind = Some Accept_no_usable_progress
      ; stop_reason = Some Agent_core.Types.MaxTokens
      ; _
      } ->
    Some `Truncated_no_progress
  | Accept_rejected _
  | Runtime_exhausted _
  | Capacity_backpressure _
  | Resumable_cli_session _
  | Internal_unhandled_exception _
  | Internal_bridge_exception _
  | Internal_contract_rejected _
  | Incomplete_tool_transcript _
  | Terminal_effect_failed _
  | Provider_attempt_effect_fenced _
  | Tool_correction_lost _
  | Receipt_persistence_failed _
  | Gate_replay_repair_required _ ->
    None

let accept_rejection_has_no_progress_retry_hint err =
  match accept_no_progress_retry_kind err with
  | Some (`Empty_no_progress | `Thinking_only_no_progress) ->
    true
  | Some `Truncated_no_progress -> false
  | None -> false

(* The typed value rides the carrier (RFC-0371 B12 §6.1(1)); the message
   keeps the exact prefixed-JSON spelling so anything that only stringifies
   — logs, receipts, persisted turn state — sees the same wire text as
   before the carrier existed. *)
type Agent_core.Error.carrier += Masc_internal of masc_internal_error

let core_error_of_masc_internal_error err =
  Agent_core.Error.Internal_carried
    { message =
        masc_internal_error_prefix
        ^ Yojson.Safe.to_string (masc_internal_error_to_json err)
    ; carrier = Masc_internal err
    }


(* ------------------------------------------------------------------ *)
(* Reverse direction: agent-core envelope -> typed variant.                  *)
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
                      fields ->
               let retry_after =
                 match float_opt_of_assoc "retry_after_sec" json with
                 | None -> No_retry_hint
                 | Some s -> Explicit s
               in
               Some
                 (Capacity_backpressure
                    { runtime_id; source; detail; retry_after })
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
                       Agent_core.Types.stop_reason_of_string
                       (string_opt_of_assoc "stop_reason" json);
                   reason;
                 })
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
      | Some (`String "incomplete_tool_transcript") -> (
          match
            string_opt_of_assoc "reason" json,
            string_opt_of_assoc "detail" json
          with
          | Some reason, Some detail ->
            (match transcript_quarantine_reason_of_string reason with
             | Some reason ->
               Some
                 (Incomplete_tool_transcript
                    { reason
                    ; detail
                    ; tool_use_ids = string_list_of_assoc "tool_use_ids" json
                    })
             | None -> None)
          | _ -> None)
      | Some (`String "terminal_effect_failed")
        when exact_fields
               [ "kind"; "failure_class"; "effect_disposition"; "diagnostic" ]
               fields -> (
          match
            string_opt_of_assoc "failure_class" json,
            string_opt_of_assoc "effect_disposition" json,
            string_opt_of_assoc "diagnostic" json
          with
          | Some failure_class, Some effect_disposition, Some diagnostic ->
            (match
               Tool_result.tool_failure_class_of_string failure_class,
               Tool_result.failure_effect_disposition_of_string effect_disposition
             with
             | Some failure_class, Some effect_disposition ->
               Some
                 (Terminal_effect_failed
                    { failure_class; effect_disposition; diagnostic })
             | _ -> None)
          | _ -> None)
      | Some (`String kind)
        when String.equal kind provider_attempt_effect_fenced_kind
             && exact_fields
                  [ "kind"; "runtime_id"; "effect_disposition"; "diagnostic" ]
                  fields ->
        (match
           string_opt_of_assoc "runtime_id" json,
           string_opt_of_assoc "effect_disposition" json,
           string_opt_of_assoc "diagnostic" json
         with
         | Some runtime_id, Some effect_disposition, Some diagnostic ->
           Option.map
             (fun effect_disposition ->
                Provider_attempt_effect_fenced
                  { runtime_id; effect_disposition; diagnostic })
             (Keeper_provider_attempt_effect_core.of_string effect_disposition)
         | _ -> None)
      | Some (`String kind)
        when String.equal kind tool_correction_lost_kind
             && exact_fields
                  [ "kind"
                  ; "runtime_id"
                  ; "effect_disposition"
                  ; "reject_count"
                  ; "diagnostic"
                  ]
                  fields ->
        (match
           string_opt_of_assoc "runtime_id" json,
           string_opt_of_assoc "effect_disposition" json,
           List.assoc_opt "reject_count" fields,
           string_opt_of_assoc "diagnostic" json
         with
         | Some runtime_id, Some effect_disposition, Some (`Int reject_count),
           Some diagnostic ->
           Option.map
             (fun effect_disposition ->
                Tool_correction_lost
                  { runtime_id; effect_disposition; reject_count; diagnostic })
             (Keeper_provider_attempt_effect_core.of_string effect_disposition)
         | _ -> None)
      | Some (`String "receipt_persistence_failed") -> (
          match string_opt_of_assoc "detail" json with
          | Some detail -> Some (Receipt_persistence_failed { detail })
          | _ -> None)
      | Some (`String "gate_replay_repair_required")
        when exact_fields
               [ "kind"; "approval_id"; "operation"; "stage"; "detail" ]
               fields -> (
          match
            string_opt_of_assoc "approval_id" json,
            string_opt_of_assoc "operation" json,
            string_opt_of_assoc "stage" json,
            string_opt_of_assoc "detail" json
          with
          | Some approval_id, Some operation, Some stage, Some detail ->
            Option.map
              (fun stage ->
                 Gate_replay_repair_required
                   { approval_id; operation; stage; detail })
              (gate_replay_repair_stage_of_string stage)
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

let classify_masc_internal_error (err : Agent_core.Error.t) :
    masc_internal_error option =
  let terminal_effect_failed ~effect_disposition ~diagnostic =
    let effect_disposition =
      match Agent_core.Error.terminal_effect_disposition effect_disposition with
      | Agent_core.Tool_contract.Proven_pre_effect ->
        Tool_result.Proven_pre_effect
      | Agent_core.Tool_contract.Proven_post_effect ->
        Tool_result.Proven_post_effect
      | Agent_core.Tool_contract.Effect_outcome_unknown ->
        Tool_result.Effect_outcome_unknown
    in
    Some
      (Terminal_effect_failed
         { failure_class = Tool_result.Runtime_failure
         ; effect_disposition
         ; diagnostic
         })
  in
  match err with
  (* Live values carry the typed payload (RFC-0371 B12); the string parse
     below stays as the boundary for persisted strings and for [Internal]
     values from producers that predate the carrier. *)
  | Agent_core.Error.Internal_carried { carrier = Masc_internal err; _ } -> Some err
  | Agent_core.Error.Internal_carried { message; _ } ->
    classify_masc_internal_error_of_string message
  | Agent_core.Error.Internal msg -> classify_masc_internal_error_of_string msg
  | Agent_core.Error.Agent
      (Agent_core.Error.TerminalToolEffectFailed
        { effect_disposition; detail; _ }) ->
    terminal_effect_failed ~effect_disposition ~diagnostic:detail
  | Agent_core.Error.Agent
      (Agent_core.Error.TerminalToolDurabilityFailed
        { effect_disposition; detail; _ }) ->
    terminal_effect_failed ~effect_disposition ~diagnostic:detail
  | _ -> None
