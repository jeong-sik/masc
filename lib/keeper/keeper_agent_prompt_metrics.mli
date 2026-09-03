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

    The measured values are not exported on their own. Joining them to the
    reason is one rule, and a caller able to reach both halves could implement
    that rule a second time -- which is what left the no-detail branch
    untested until this function existed. {!provenance_failure_reason} stays
    exported because a reason may become a metric label; there is no such use
    for the values alone. *)

(** Why a turn carries no byte attribution.

    [Dispatch_not_reached] says no request reached a provider on the attempt
    that settled the turn. [Input_provenance_unresolved] says a request did go
    out and the messages it carried could not be resolved back to provider
    content; the carried {!provenance_failure} names which check refused.
    [Client_session_holds_input] says the request went out on an
    official-client lane that resumed a conversation the client owns
    server-side: masc transmitted only this turn's new material, so the input
    the model actually read is not observable from this process at all.

    The three are separated because they are fixed differently, and because a
    fleet reading one number cannot tell a turn that never dispatched from a
    turn whose input the reader failed to classify, nor either of those from a
    turn whose input was never this process's to measure. *)
type attribution_gap =
  | Dispatch_not_reached
  | Input_provenance_unresolved of provenance_failure
  | Client_session_holds_input

(** Byte attribution of one turn's model input.

    [Attributed] carries the measured segments. There is no total field: a
    stored sum can disagree with the segments it claims to sum, and
    {!attributed_bytes} computes it from the segments instead.
    [Attributed { segments = [] }] is a turn that was measured and attributed
    nothing, which is not the same fact as [Not_measured] -- the constructor,
    not the byte count, is what separates them.

    [runtime_profile] is the runtime id of the lane attempt that produced this
    attribution. A turn that failed over records the settled runtime elsewhere,
    so the two can differ; keeping the producing lane beside the value lets a
    reader compare instead of assuming.

    [Not_measured] carries no byte count at all. *)
type ctx_attribution =
  | Attributed of
      { runtime_profile : string
      ; segments : (Turn_record.input_component_id * prompt_segment_metrics) list
      }
  | Not_measured of attribution_gap

(** Per-bucket attribution of an Agent.run input window.
    [actual_input_tokens] is provider-reported and only known after a response;
    it is not attributed to byte segments and is recorded whether or not the
    byte attribution succeeded. *)
type ctx_composition_metrics =
  { actual_input_tokens : int option
  ; attribution : ctx_attribution
  }

val attributed_bytes : ctx_attribution -> int option
(** The sum of the attributed segments' bytes, or [None] for [Not_measured].

    Folding the [None] back to a number restores the defect this type was
    introduced to remove: a caller that needs a figure has to branch on
    [Not_measured] and say so in its own output. *)

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

(** Remove the AGENT_CORE-generated [extra_system_context] carrier from a list a
    runtime actually transmitted, by the carrier's typed metadata identity.

    Ordering is not checked. {!provider_content_messages} compares a
    projection against the list it was handed; a caller holding only the
    transmitted list has no such pair, and on a lane whose tail window drops
    the head by design that comparison refuses every turn. What remains
    checkable here is carrier identity: an invalid, duplicated, repeated, or
    unexpectedly absent carrier returns the matching {!provenance_failure}.

    A carrier the window cut away returns
    [Prompt_context_presence_mismatch]. *)
val provider_content_of_transmitted :
  prompt_context_present:bool ->
  messages:Agent_core.Types.message list ->
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

(** Bucket the exact bytes of one request's content.

    [prompt_blocks] are the turn's injected prompt components, [tools] are the
    canonical schemas as sent, and [input_messages] are the provider content
    messages. Only these concrete content values are counted; provider
    serialization metadata is not estimated.

    Segments and the provider token count are built separately because they
    become known at different times: the segments are fixed once the request is
    assembled, the token count only after a response. *)
val build_ctx_segments :
  prompt_blocks:Turn_record.prompt_block list ->
  tools:Agent_core.Tool.t list ->
  input_messages:Agent_core.Types.message list ->
  (Turn_record.input_component_id * prompt_segment_metrics) list

val ctx_composition_to_json : ctx_composition_metrics -> Yojson.Safe.t
(** Emit the record as ["actual_input_tokens"] plus an ["attribution"] object.

    [Attributed] emits ["status": "attributed"] with ["runtime_profile"],
    ["attributed_bytes"] and ["segments"]. [Not_measured] emits
    ["status": "not_measured"] with ["reason"] and ["detail"], and emits
    neither ["attributed_bytes"] nor ["segments"]: a reader that finds no
    total has to decide what to show, while a reader handed a zero shows a
    turn that cost nothing.

    This is a hard cut. Rows written before the ["attribution"] key existed
    cannot say whether their turn was measured, and no reader here converts
    them. *)
