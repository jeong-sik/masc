(** Structured keeper-internal error envelopes carried through
    [Agent_core.Error.Internal]. *)

(** Canonical wire kind emitted for {!Capacity_backpressure}.  Receipt
    terminal projection and decoding consume this same value. *)
val capacity_backpressure_kind : string
(** Canonical wire kind for structural transcript corruption rejected before
    provider dispatch. *)
val incomplete_tool_transcript_kind : string

(** Canonical wire kind for a provider-attempt failure whose effect disposition
    forbids same-turn replay. *)
val provider_attempt_effect_fenced_kind : string

(** Canonical wire kind for a fenced provider-attempt failure whose turn also
    carried typed pre_tool_use rejections: the model's correction round-trip
    was the visible casualty (masc#28885). Fence semantics are identical to
    {!provider_attempt_effect_fenced_kind}; only the label differs. *)
val tool_correction_lost_kind : string

(** Canonical wire kind for a response MASC's own accept contract refused. *)
val accept_rejected_kind : string

(** Canonical wire kind for a failed turn-closing tool effect, or one that
    returned no typed receipt for what it did. *)
val terminal_effect_failed_kind : string

type provider_rejection = {
  provider_label : string;
  reason : string;
}

type capacity_backpressure_source =
  | Provider_capacity
  | Client_capacity
  | Runtime_slot

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

val runtime_exhaustion_reason_retryable : runtime_exhaustion_reason -> bool

val runtime_exhaustion_reason_to_label : runtime_exhaustion_reason -> string
(** Human-readable label carrying the [detail]/[message] payload inline,
    for {!summary_of_masc_internal_error} and log lines. Distinct from
    {!runtime_exhaustion_reason_to_json}'s bare wire tags. *)

val runtime_exhaustion_reason_to_json : runtime_exhaustion_reason -> Yojson.Safe.t
val runtime_exhaustion_reason_of_json : Yojson.Safe.t -> runtime_exhaustion_reason option

type accept_rejection_kind =
  | Accept_no_usable_progress
  | Accept_predicate_rejected

(** The wire label for a {!Llm_provider.Http_client.network_error_kind}.
    Exported because [Keeper_agent_error] renders the same seven kinds for
    its own [network_kind] field and kept a byte-identical copy; two
    mappings for one type can be renamed apart. *)
val network_error_kind_to_string :
  Llm_provider.Http_client.network_error_kind -> string

val accept_rejection_kind_to_string : accept_rejection_kind -> string
type accept_response_shape =
  | Accept_response_empty
  | Accept_response_thinking_only
  | Accept_response_blank_text_only
  | Accept_response_tool_result_only
  | Accept_response_media_only
  | Accept_response_mixed_without_deliverable_content
  | Accept_response_has_deliverable_content

val accept_response_shape_of_agent_core :
  Agent_core.Response_shape.content_shape -> accept_response_shape

type transcript_quarantine_reason =
  | Structurally_invalid
  | Unresolved_tool_results

type gate_replay_repair_stage =
  | Replay_resolution_lookup
  | Replay_request_decode
  | Replay_evidence_storage
  | Replay_evidence_retrieval
  | Replay_journal
  | Replay_stale_grant_retirement
  | Replay_invalid_resolution_state

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
         [MaxTokens] on an empty/thinking_only shape marks a truncation, distinct
         from a clean [EndTurn] no-progress terminal. Groundwork slice: threaded
         and serialized, not yet consumed by classification. *)
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
  | Internal_contract_rejected of { reason : string }
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
      (** A provider attempt failed after an effect was attempted or after the
          runtime lost complete effect observation. The exact source must be
          terminalized as failed, never replayed automatically. *)
  | Tool_correction_lost of {
      runtime_id : string;
      effect_disposition : Keeper_provider_attempt_effect_core.t;
      reject_count : int;
      diagnostic : string;
    }
      (** The same fence, on a turn that also recorded typed pre_tool_use
          rejections: the runtime escalated a corrective tool error into the
          turn's death (masc#28885). Disposition is identical to
          {!Provider_attempt_effect_fenced} — never replayed in-turn — the
          label exists so operators can tell a lost correction from an
          ordinary fenced provider failure. *)
  | Receipt_persistence_failed of { detail : string }
  | Gate_replay_repair_required of {
      approval_id : string;
      operation : string;
      stage : gate_replay_repair_stage;
      detail : string;
    }

val runtime_runner_execute_site : string

val blocker_detail_structured_max_chars : int
(** Upper bound (~2000) preserved for a [masc_agent_core_error] structured payload
    by {!cap_blocker_detail}. *)

val cap_blocker_detail : string -> string
(** [cap_blocker_detail s] bounds a keeper [blocker_info] detail string: a
    structured payload beginning with [masc_internal_error_prefix] (#9933) is
    preserved up to {!blocker_detail_structured_max_chars}; plain narrative
    text is truncated to the narrative budget (~200). Idempotent. *)

val masc_internal_error_to_json : masc_internal_error -> Yojson.Safe.t

val summary_of_masc_internal_error : masc_internal_error -> string option

(** The closed set of wire kinds {!kind_of_masc_internal_error} can emit — one
    per {!masc_internal_error} constructor.

    It exists because the wire is a string and the receipt classifier
    ([Keeper_terminal_reason.of_wire]) had to guess the string back. It knew
    five of the thirteen and read the rest as an unrecognised state, so a
    keeper's own named failures reached the operator as "unmapped runtime
    state" (#29929). Matching this type instead makes a new constructor a
    compile obligation at every consumer, which is what
    [Keeper_turn_terminal_code] already promises for the layer above. *)
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

val wire_kind_to_string : wire_kind -> string

(** [None] for any string this module does not emit, including the agent-core
    and provider wire families that travel the same receipt field. *)
val wire_kind_of_string : string -> wire_kind option

val kind_of_masc_internal_error : masc_internal_error -> string

val runtime_id_of_masc_internal_error : masc_internal_error -> string

val accept_no_progress_retry_kind :
  masc_internal_error ->
  [ `Empty_no_progress | `Thinking_only_no_progress | `Truncated_no_progress ] option

val accept_rejection_has_no_progress_retry_hint : masc_internal_error -> bool

val core_error_of_masc_internal_error :
  masc_internal_error -> Agent_core.Error.t

val parse_masc_internal_error_json :
  Yojson.Safe.t -> masc_internal_error option

val classify_masc_internal_error_of_string :
  string -> masc_internal_error option

val classify_masc_internal_error :
  Agent_core.Error.t -> masc_internal_error option
