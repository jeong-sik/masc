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
  ; segments : (string * prompt_segment_metrics) list
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

(** Mutate [totals] by adding [metric] into [bucket]. *)
val add_segment_metric :
  (string, prompt_segment_metrics) Hashtbl.t ->
  bucket:string ->
  prompt_segment_metrics ->
  unit

(** Project a single [content_block] of [role] to its segment metric. *)
val metric_of_block :
  role:Agent_sdk.Types.role ->
  Agent_sdk.Types.content_block ->
  prompt_segment_metrics

(** Pick the segment bucket name for a history block. *)
val history_bucket_of_block :
  role:Agent_sdk.Types.role -> Agent_sdk.Types.content_block -> string

(** [actual_input_tokens] is provider-reported and only known after a response.
    It is not attributed to byte segments. [attributed_bytes] sums only the
    exact textual/JSON components represented by [segments]. *)
val build_ctx_composition_metrics :
  system_prompt:string ->
  dynamic_context:string ->
  memory_context:string ->
  temporal_context:string ->
  user_message:string ->
  history_messages:Agent_sdk.Types.message list ->
  actual_input_tokens:int option ->
  ctx_composition_metrics

val ctx_composition_to_json : ctx_composition_metrics -> Yojson.Safe.t
