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
  ; request_boundary_observed : bool
  ; segments : (string * prompt_segment_metrics) list
  }

type request_boundary_attribution =
  { extra_system_context_blocks : (Prompt_block_id.t * string) list
  ; current_user_message_index : int option
  ; extra_system_context_message_index : int option
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

(** Build byte attribution after OAS has applied [model_input_projection].
    [messages] is the final message list OAS will send to its provider. The
    original current User prompt and OAS-appended extra-system-context message
    are identified by their pre-projection indices; MASC projections preserve
    existing message order and may only rewrite content or append Gate evidence.
    MASC-owned extra-context blocks are attributed individually, while the OAS
    system-context prefix, pre-existing context, and join separators remain in
    [extra_system_context_existing_or_joiners]. Tool schemas use the same
    canonical schema JSON projection as wake telemetry. *)
val build_ctx_composition_metrics :
  system_prompt:string ->
  attribution:request_boundary_attribution ->
  messages:Agent_sdk.Types.message list ->
  tools:Agent_sdk.Tool.t list ->
  actual_input_tokens:int option ->
  ctx_composition_metrics

val with_actual_input_tokens :
  ctx_composition_metrics -> int option -> ctx_composition_metrics
(** Attach the aggregate provider-reported input token count after the response.
    Tokens remain unallocated across byte segments. *)

val unavailable_ctx_composition :
  actual_input_tokens:int option -> ctx_composition_metrics
(** Explicit incomplete observation used only when no request-boundary hook ran.
    It never fabricates a partial composition from stale pre-run inputs. *)

val ctx_composition_to_json : ctx_composition_metrics -> Yojson.Safe.t
