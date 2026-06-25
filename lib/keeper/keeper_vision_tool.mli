(** Impure shell of the [analyze_image] keeper tool.
    RFC-keeper-vision-delegation-tool §2.6.

    Loads an image artifact (raw bytes) from {!Multimodal.Vision_artifact_store},
    base64-encodes it into a one-shot [text; image] message, sub-calls a
    configured vision runtime ({!Runtime_agent.first_media_capable_runtime}
    order), and classifies the reply via {!Multimodal.Vision_analyze}. The image
    is read only inside this sub-call; it never enters the keeper's own
    conversation. Every failure path is a typed JSON error — never a silent empty
    success (the failure class the RFC targets).

    Mirrors the provider-sub-call shape of [Keeper_librarian_runtime]; the small
    [complete_fn] / [with_timeout] helpers are replicated here rather than shared,
    until a third sub-call consumer justifies extracting a common module. *)

type complete_fn =
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Llm_provider.Provider_config.t ->
  messages:Agent_sdk.Types.message list ->
  unit ->
  (Agent_sdk.Types.api_response, Llm_provider.Http_client.http_error) result

val truncated_of_stop_reason : Agent_sdk.Types.stop_reason -> bool
(** Collapse the provider's typed terminal reason to the single [truncated] bit
    {!Multimodal.Vision_analyze.classify} consumes: [MaxTokens -> true], every
    other variant -> [false]. Exhaustive so a new SDK variant forces a decision. *)

val message_of_request
  :  Multimodal.Vision_analyze.request
  -> Agent_sdk.Types.message
(** One-shot user message [text query; image], with bytes base64-encoded and
    [~source_type:"base64"] (the OpenAI/ollama serializer emits
    [data:<media_type>;base64,<data>]). *)

val provider_for_vision
  :  Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t
(** A one-shot, non-thinking, plain-text vision config: thinking off (avoids the
    2026-06-25 gemma4 thinking-budget exhaustion that produced empty replies),
    [response_format = Off], [tool_choice = None], [temperature = 0], and a
    fallback [max_tokens] only when the selected runtime has not configured one. *)

val first_vision_runtime_id : unit -> (string, string) result
(** Runtime id of the first image-capable configured runtime, or [Error] when
    none is configured. *)

val vision_store_dir : keeper_name:string -> string
(** Per-keeper content-addressed vision store directory, shared by [handle]'s
    load path and {!intercept_image_blocks}, so a handle stored at ingestion
    resolves on a later analyze_image call. *)

val should_delegate : Multimodal.Multimodal_policy.t option -> bool
(** [true] iff the (optional, default-resolved via {!Multimodal.Multimodal_policy})
    policy delegates images. [None] resolves to the system default (Reroute ->
    [false]), so a keeper with no configured policy is unaffected. *)

val intercept_image_blocks
  :  store:(string -> (string, string) result)
  -> Agent_sdk.Types.content_block list
  -> Agent_sdk.Types.content_block list
(** RFC-keeper-vision-delegation-tool §2.3 (site 1). Replace each [Image] block
    with a [Text] placeholder referencing the handle [store] returns for the
    decoded raw bytes. Fail-open: on a base64-decode or [store] error the original
    [Image] is kept (and a WARN logged), degrading to RFC-0265 reroute rather than
    dropping the user's image. All non-image blocks (including any future block
    variant) pass through unchanged. [store] is injectable so the transform is
    unit-testable without filesystem I/O. *)

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
(** Tool entry. [args] = [{ "artifact": handle; "query": string;
    "media_type"?: string }]. [media_type], when provided, must be a supported
    image MIME type; otherwise the stored bytes are sniffed. Returns a JSON
    string: [{"ok":true,"text":...}] or
    [{"ok":false,"error":code,"failure_class":class[,"detail":...]}] with code
    one of [invalid_args | eio_context_unavailable | artifact_load_failed |
    invalid_media_type | invalid_request | no_capable_runtime | timeout |
    provider_error | empty_extraction | truncated_extraction]. [complete]
    defaults to the live provider call (inject in tests). Never returns a raw
    empty success. *)
