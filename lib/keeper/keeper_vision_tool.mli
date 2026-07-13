(** Impure shell of the [analyze_image] keeper tool.
    RFC-keeper-vision-delegation-tool §2.6.

    Loads an image artifact (raw bytes) from {!Multimodal.Vision_artifact_store},
    base64-encodes it into a one-shot [text; image] message, sub-calls
    configured vision runtimes in media-failover order, and classifies the reply
    via {!Multimodal.Vision_analyze}. The image is read only inside this sub-call;
    it never enters the keeper's own
    conversation. Every failure path is a typed JSON error — never a silent empty
    success (the failure class the RFC targets).

    Mirrors the provider-sub-call shape of [Keeper_librarian_runtime]; the small
    [complete_fn] / [with_timeout] helpers are replicated here rather than shared,
    until a third sub-call consumer justifies extracting a common module.
    Artifact filesystem I/O is offloaded through {!Eio_guard.run_in_systhread}
    when the Eio runtime is active, so durable fsync/rename work does not block
    the shared Eio domain. *)

type complete_fn =
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Llm_provider.Provider_config.t ->
  messages:Agent_sdk.Types.message list ->
  unit ->
  (Agent_sdk.Types.api_response, Llm_provider.Http_client.http_error) result

val vision_default_max_tokens : int
(** Fallback output budget for the one-shot vision sub-call when the selected
    runtime has not configured [max_tokens]. *)

val max_image_bytes : unit -> int
(** Maximum raw artifact bytes accepted by the tool before base64 provider-message
    construction, from [MASC_KEEPER_VISION_MAX_IMAGE_BYTES] / runtime TOML boot
    overrides with a 5 MiB default matching dashboard upload policy. Oversized
    artifacts fail closed with [image_too_large]. *)

val supported_image_media_types : string list
(** MIME types admitted by [analyze_image]. The tool schema and runtime
    validation share this list. *)

val validate_media_type : string -> (string, string) result
(** Normalize and validate an image MIME type against
    {!supported_image_media_types}. *)

val validate_image_size : string -> (unit, string) result
(** Validate raw image bytes against {!max_image_bytes}. *)

val truncated_of_stop_reason : Agent_sdk.Types.stop_reason -> bool
(** Collapse the provider's typed terminal reason to the single [truncated] bit
    {!Multimodal.Vision_analyze.classify} consumes: [MaxTokens -> true], every
    other variant -> [false]. Exhaustive so a new SDK variant forces a decision. *)

val message_of_request
  :  Multimodal.Vision_analyze.request
  -> Agent_sdk.Types.message
(** One-shot user message [text query; image], with bytes base64-encoded and
    [~source_type:Agent_sdk.Types.Base64] (the OpenAI/ollama serializer emits
    [data:<media_type>;base64,<data>]). *)

val provider_for_vision
  :  runtime_id:string
  -> Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t
(** A one-shot, non-thinking, structured-output vision config: thinking off (avoids the
    2026-06-25 gemma4 thinking-budget exhaustion that produced empty replies),
    [response_format = JsonSchema _], [output_schema = Some _],
    [tool_choice = None], the selected runtime's declared temperature (or the
    deterministic subsystem fallback), and a fallback [max_tokens] only when
    the selected runtime has not configured one. *)

val vision_runtime_ids : unit -> string list
(** Ordered schema-capable image runtime ids: [\[runtime\].media_failover] order
    first, then declaration order. The handler tries these candidates in order
    for timeout/provider failures within one cumulative tool deadline. *)

val first_vision_runtime_id : unit -> (string, string) result
(** Compatibility helper returning the first entry of {!vision_runtime_ids}, or
    [Error] when none is configured. *)

val vision_store_dir : keeper_name:string -> string
(** Per-keeper artifact store directory used by [analyze_image] and eager image
    eviction. *)

val store_artifact
  :  dir:string
  -> string
  -> (Multimodal.Vision_artifact_store.handle, string) result
(** Store image bytes in the content-addressed artifact store. Blocking
    filesystem work is offloaded when the Eio runtime is active. *)

val load_artifact
  :  dir:string
  -> Multimodal.Vision_artifact_store.handle
  -> (string, string) result
(** Load image bytes from the content-addressed artifact store. Blocking
    filesystem work is offloaded when the Eio runtime is active. *)

(** Typed outcome of {!run_vision}. SSOT shared by the tool handler (renders to
    JSON) and eager ingestion eviction ({!Keeper_vision_ingest}, renders to a
    placeholder). *)
type vision_outcome =
  | Vo_ok of string
  | Vo_invalid_request of string
  | Vo_no_runtime of string
  | Vo_timeout
  | Vo_invalid_structured_response of string
  | Vo_provider of { failure_class : Tool_result.tool_failure_class; detail : string }
  | Vo_empty
  | Vo_truncated

val run_vision
  :  ?complete:complete_fn
  -> ?timeout_sec:float
  -> sw:Eio.Switch.t
  -> clock:float Eio.Time.clock_ty Eio.Resource.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> query:string
  -> media_type:string
  -> bytes:string
  -> unit
  -> vision_outcome
(** The bounded one-shot vision sub-call core (runtime resolution + provider
    call under [with_timeout] + §2.2 classification). Used by {!handle} and by
    eager ingestion. Requires the turn clock, so eager ingestion cannot run an
    unbounded provider call. Non-cancellation exceptions are converted to
    [Vo_provider]; provider success with malformed structured output is
    [Vo_invalid_structured_response], so eager ingestion can keep the turn alive
    with a typed unread placeholder. *)

val handle
  :  ?complete:complete_fn
  -> ?timeout_sec:float
  -> ?sw:Eio.Switch.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> meta:Keeper_meta_contract.keeper_meta
  -> args:Yojson.Safe.t
  -> unit
  -> string

val handle_with_outcome
  :  ?complete:complete_fn
  -> ?timeout_sec:float
  -> ?sw:Eio.Switch.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> meta:Keeper_meta_contract.keeper_meta
  -> args:Yojson.Safe.t
  -> unit
  -> Keeper_tool_execution.t
(** Tool entry. [args] = [{ "artifact": handle; "query": string;
    "media_type"?: string }]. [media_type], when provided, must be a supported
    image MIME type; otherwise the stored bytes are sniffed fail-closed. Requires
    [sw], [net], and [clock]; missing Eio context is [Runtime_failure]. Returns a JSON
    string: [{"ok":true,"text":...}] or
    [{"ok":false,"error":code,"failure_class":class[,"detail":...]}] with code
    one of [invalid_args | eio_context_unavailable | artifact_load_failed |
    invalid_timeout | image_too_large | invalid_media_type | invalid_request |
    no_capable_runtime | timeout | provider_error | empty_extraction |
    truncated_extraction]. [complete] defaults to the live provider call (inject
    in tests). Never returns a raw empty success. *)
