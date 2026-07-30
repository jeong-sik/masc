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

(** Build a disjoint snapshot at the existing model-input projection boundary.
    [system_prompt_block] is separate because OAS carries it in provider
    configuration rather than [input_messages]. Dynamic, temporal, and memory
    prompt blocks remain provenance in [Turn_record.blocks]; their flattened
    provider representation is counted once in [input_messages] and is not
    reverse-engineered here. *)
val build_input_components :
  system_prompt_block:Turn_record.prompt_block option ->
  tools:Agent_sdk.Tool.t list ->
  input_messages:Agent_sdk.Types.message list ->
  Turn_record.input_component list

(** Attach provider-reported token usage to a previously captured byte
    composition. The two units remain separate. *)
val build_ctx_composition_metrics :
  input_components:Turn_record.input_component list ->
  actual_input_tokens:int option ->
  ctx_composition_metrics

val ctx_composition_to_json : ctx_composition_metrics -> Yojson.Safe.t
