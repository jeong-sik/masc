(** Prompt metrics for keeper Agent.run turns. *)

(** Structured prompt result from [build_turn_prompt] callback.
    [system_prompt] holds hard constraints; [dynamic_context]
    holds soft context injected via OAS [extra_system_context]. *)
type turn_prompt =
  { system_prompt : string
  ; dynamic_context : string
  }

(** Prompt segment metrics for effective keeper input attribution.
    Bytes are stored rather than character counts because prompts are UTF-8. *)
type prompt_segment_metrics =
  { bytes : int
  ; estimated_tokens : int
  ; fingerprint : string option
  }

(** Effective prompt metrics for a keeper turn.
    [estimated_cacheable_tokens] tracks the system prompt portion only
    because OAS prompt caching is enabled via [cache_system_prompt:true]. *)
type prompt_metrics =
  { fingerprint : string
  ; estimated_total_tokens : int
  ; estimated_cacheable_tokens : int
  ; system_prompt_segment : prompt_segment_metrics
  ; dynamic_context_segment : prompt_segment_metrics
  ; user_message_segment : prompt_segment_metrics
  }

(** Per-bucket attribution of an Agent.run input window. *)
type ctx_composition_metrics =
  { actual_input_tokens : int option
  ; display_total_tokens : int
  ; estimated_known_tokens : int
  ; segments : (string * prompt_segment_metrics) list
  }

val empty_prompt_segment_metrics : prompt_segment_metrics

(** Compute byte/token/fingerprint for a single text segment after
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

(** Build a synthetic segment with [bytes=0] and no fingerprint —
    used for the [unattributed] tail bucket. *)
val synthetic_prompt_segment_metrics :
  estimated_tokens:int -> prompt_segment_metrics

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

(** [actual_input_tokens] is the LLM-reported input token count and is
    only known after a provider response. Pre-call sites (prompt build)
    must pass [None]; post-response sites pass [Some n]. *)
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
