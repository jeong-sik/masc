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
  ; sdk_turn : int
  ; prepared_component_bytes : int
  ; request_body_bytes : int option
  ; request_body_sha256 : string option
  ; origin_segments : (string * prompt_segment_metrics) list
  ; content_segments : (string * prompt_segment_metrics) list
  ; context_block_segments : (string * prompt_segment_metrics) list
  }

type prepared_input_snapshot =
  { sdk_turn : int
  ; messages : Agent_sdk.Agent.prepared_message list
  ; context_blocks : Turn_record.prompt_block list
  }

type request_wire_snapshot =
  { sdk_turn : int
  ; observation : Agent_sdk.Llm_provider.Request_wire_observer.observation
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

(** Build the last SDK turn's prepared-input composition from OAS typed
    origins. [prepared_component_bytes] is the sum of the system prompt, the
    canonical tool-schema array, and canonical serialized prepared messages.
    It is not the provider wire size. [request_wire], when present, is the
    independently observed exact provider serialization prepared before
    dispatch. [context_blocks] is a drill-down of the extra-system assembly
    and is intentionally not added again to [prepared_component_bytes]. *)
val build_ctx_composition_metrics :
  sdk_turn:int ->
  system_prompt:string ->
  tools:Agent_sdk.Tool.t list ->
  prepared_messages:Agent_sdk.Agent.prepared_message list ->
  context_blocks:Turn_record.prompt_block list ->
  request_wire:Agent_sdk.Llm_provider.Request_wire_observer.observation option ->
  actual_input_tokens:int option ->
  ctx_composition_metrics

val ctx_composition_to_json : ctx_composition_metrics -> Yojson.Safe.t
