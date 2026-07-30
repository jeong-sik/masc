(** Prompt metrics for keeper Agent.run turns. *)

(** Structured prompt result from [build_turn_prompt] callback.
    [system_prompt] holds hard constraints; [dynamic_context]
    holds soft context injected through OAS [extra_system_context]. *)
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

(** Return the concrete provider content messages without double-counting
    OAS's generated [extra_system_context] carrier. [projection_input] is the
    list OAS passes to the model-input projection; when prompt context exists,
    its final message carries the same prompt blocks counted separately.
    Projection-only messages appended after that input (for example typed Gate
    replay evidence) remain included. If the projection rewrites or reorders
    its input instead of preserving the exact prefix, return [None] rather than
    guess an attribution. *)
val provider_content_messages :
  prompt_context_present:bool ->
  projection_input:Agent_sdk.Types.message list ->
  projected_messages:Agent_sdk.Types.message list ->
  Agent_sdk.Types.message list option

val empty_prompt_segment_metrics : prompt_segment_metrics

(** Compute byte count and fingerprint for a single text segment after
    UTF-8 sanitisation. *)
val prompt_segment_metrics_of_text : string -> prompt_segment_metrics

val build_prompt_metrics :
  system_prompt:string ->
  dynamic_context:string ->
  user_message:string ->
  prompt_metrics

val prompt_segment_metrics_to_json :
  prompt_segment_metrics -> Yojson.Safe.t

val prompt_metrics_to_json : prompt_metrics -> Yojson.Safe.t

(** [actual_input_tokens] is provider-reported and only known after a response.
    It is not attributed to byte segments. [prompt_blocks] are the final SDK
    turn's exact injected prompt components, [tools] are the canonical schemas,
    and [input_messages] are the actual model-input projection messages after
    removing only OAS's prompt-context carrier (whose raw blocks are already in
    [prompt_blocks]). [attributed_bytes] sums only these concrete content
    values; provider serialization metadata is not estimated. *)
val build_ctx_composition_metrics :
  prompt_blocks:Turn_record.prompt_block list ->
  tools:Agent_sdk.Tool.t list ->
  input_messages:Agent_sdk.Types.message list ->
  actual_input_tokens:int option ->
  ctx_composition_metrics

val ctx_composition_to_json : ctx_composition_metrics -> Yojson.Safe.t
