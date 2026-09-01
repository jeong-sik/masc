(** Prompt metrics for keeper Agent.run turns. *)

(** Structured prompt result from [build_turn_prompt] callback.
    [system_prompt] holds hard constraints; [dynamic_context]
    holds soft context injected through AGENT_CORE [extra_system_context]. *)
type turn_prompt =
  { system_prompt : string
  ; dynamic_context : string
  }

(** Prompt segment metrics for effective keeper input attribution.
    Bytes are stored rather than character counts because prompts are UTF-8. *)
type prompt_segment_metrics =
  { bytes : int
  ; fingerprint : string option
  }

(** Effective byte metrics for a keeper turn. *)
type prompt_metrics =
  { fingerprint : string
  ; total_bytes : int
  ; cacheable_bytes : int
  ; system_prompt_segment : prompt_segment_metrics
  ; dynamic_context_segment : prompt_segment_metrics
  ; user_message_segment : prompt_segment_metrics
  }

(** Per-bucket attribution of an Agent.run input window. *)
type ctx_composition_metrics =
  { actual_input_tokens : int option
  ; attributed_bytes : int
  ; segments : (Turn_record.input_component_id * prompt_segment_metrics) list
  }

(** Why a turn has no exact provider-input composition.

    One constructor per condition the check can actually distinguish, because
    the conditions do not share a fix. [Input_prefix_dropped] says the
    projection returned fewer messages than it was handed, which is what a
    history-cutting window does; [Input_prefix_rewritten] says the result was
    long enough but diverged, which is what a rewriting or reordering
    projection does. The carrier constructors separate malformed metadata from
    a carrier count that disagrees with the assembler. Collapsing these into
    one "provenance unavailable" reason is what made the antigravity turns
    unattributable without saying which of the five had happened. *)
type provenance_failure =
  | Input_prefix_dropped of
      { projection_input_messages : int
      ; projected_messages : int
      }
  | Input_prefix_rewritten of { first_divergent_index : int }
  | Prompt_context_carrier_metadata_invalid
  | Prompt_context_carrier_metadata_duplicate
  | Prompt_context_carrier_repeated
  | Prompt_context_presence_mismatch of
      { carrier_observed : bool
      ; prompt_context_present : bool
      }

val provenance_failure_reason : provenance_failure -> string
(** Stable snake_case identifier for logs and durable records. *)

val provenance_failure_summary : provenance_failure -> string
(** The line the keeper logs: the reason, plus the failure's measured values
    after a single space when it carries any.

    The two halves are not exported separately. Joining them is one rule, and
    a caller that could reach both halves could implement that rule a second
    time -- which is what left the no-detail branch untested until this
    function existed. {!provenance_failure_reason} stays exported because a
    reason may become a metric label; there is no such use for the values. *)

(** Return concrete provider content messages only when their provenance is
    unambiguous. The AGENT_CORE-generated [extra_system_context] carrier is removed by
    its typed metadata identity, never by position or content. Its presence must
    exactly agree with [prompt_context_present]. Projection-only messages remain
    included when the projection preserves the exact input prefix; a rewrite,
    reorder, missing carrier, or duplicate/invalid carrier returns the matching
    {!provenance_failure}. *)
val provider_content_messages :
  prompt_context_present:bool ->
  projection_input:Agent_core.Types.message list ->
  projected_messages:Agent_core.Types.message list ->
  (Agent_core.Types.message list, provenance_failure) result

val build_prompt_metrics :
  system_prompt:string ->
  dynamic_context:string ->
  user_message:string ->
  prompt_metrics

module For_testing : sig
  val build_prompt_metrics_with_sanitizer :
    sanitize:(string -> string) ->
    system_prompt:string ->
    dynamic_context:string ->
    user_message:string ->
    prompt_metrics
end

val prompt_metrics_to_json : prompt_metrics -> Yojson.Safe.t

(** [actual_input_tokens] is provider-reported and only known after a response.
    It is not attributed to byte segments. [prompt_blocks] are the final agent-core
    turn's exact injected prompt components, [tools] are the canonical schemas,
    and [input_messages] are the actual model-input projection messages on
    turns whose provenance is unambiguous. [attributed_bytes] sums only these
    concrete content values; provider serialization metadata is not estimated. *)
val build_ctx_composition_metrics :
  prompt_blocks:Turn_record.prompt_block list ->
  tools:Agent_core.Tool.t list ->
  input_messages:Agent_core.Types.message list ->
  actual_input_tokens:int option ->
  ctx_composition_metrics

val ctx_composition_to_json : ctx_composition_metrics -> Yojson.Safe.t
